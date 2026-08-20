'use strict';

/**
 * database.js
 * -----------------------------------------------------------------------------
 * Connection factories for MySQL and MongoDB.
 *
 * MySQL credentials are resolved from AWS Secrets Manager at boot (C3), never
 * from a plaintext env var or a hardcoded default. The app reads only
 * DB_SECRET_ARN (never the secret value) plus DB_HOST/DB_PORT (non-secret,
 * passed by modules/service's user-data). AWS_ENDPOINT_URL, when set, points
 * the SDK at LocalStack — when unset, the SDK talks to real AWS the normal
 * way (instance-profile role). There is no `if (isLocalStack)` branch here:
 * the same binary runs unchanged in both environments.
 */

const mysql = require('mysql2/promise');
const { MongoClient } = require('mongodb');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const fs = require('fs');

const DB_SECRET_ARN = process.env.DB_SECRET_ARN;
const DB_HOST = process.env.DB_HOST;
const DB_PORT = Number(process.env.DB_PORT || 3306);
// Aiven's CA cert (public root cert, not secret). modules/service's
// user-data.sh.tftpl always exports DB_CA_CERT_PATH when db_ca_cert is set,
// writing the file to /etc/app/db-ca.pem on the instance -- match that
// exact path as the fallback default here too. Falls back to no TLS only
// when the path isn't set/present, so local dev against a non-TLS MySQL
// (A1's docker-compose) keeps working unchanged.
const DB_CA_CERT_PATH = process.env.DB_CA_CERT_PATH || '/etc/app/db-ca.pem';

const MONGO_URI = process.env.MONGO_URI || 'mongodb://mongo-db:27017';
const MONGO_DB_NAME = process.env.MONGO_DB || 'capacity_lab';

const secretsClient = new SecretsManagerClient({});

// ---------------------------------------------------------------------------
// MySQL pool (singleton) — built once, from creds resolved at boot.
// ---------------------------------------------------------------------------
let pool;
let poolPromise;

async function resolveDbCredentials() {
  if (!DB_SECRET_ARN) {
    throw new Error('DB_SECRET_ARN is not set — cannot resolve DB credentials from Secrets Manager');
  }

  const result = await secretsClient.send(new GetSecretValueCommand({ SecretId: DB_SECRET_ARN }));
  // Log the ARN and version only — never the secret value (C3).
  console.log(`Resolved DB credentials from Secrets Manager: arn=${result.ARN} versionId=${result.VersionId}`);

  const envelope = JSON.parse(result.SecretString);
  return {
    username: envelope.username,
    password: envelope.password,
    database: envelope.dbname,
  };
}

async function buildPool() {
  const creds = await resolveDbCredentials();

  const ssl = fs.existsSync(DB_CA_CERT_PATH)
    ? { ca: fs.readFileSync(DB_CA_CERT_PATH, 'utf8') }
    : undefined;

  return mysql.createPool({
    host: DB_HOST,
    port: DB_PORT,
    user: creds.username,
    password: creds.password,
    database: creds.database,
    ssl,

    // Sized from measured demand: Little's Law (L = lambda*W) with the
    // reproduce-OPS-2202 burst (~1620 req/s, ~1.73ms/query) gives an average
    // need of ~2.8 concurrent connections. Raised to 50 after OPS-2203 showed
    // 20 saturating (Threads_connected~21/Max_used_connections~22) under a
    // 500-VU admissions surge -- still well under MySQL's max_connections=151.
    waitForConnections: true,
    connectionLimit: 50,
    queueLimit: 0,
    connectTimeout: 10_000,
    maxIdle: 50,
    idleTimeout: 60_000,
    enableKeepAlive: true,
  });
}

async function getPool() {
  if (pool) return pool;
  if (!poolPromise) {
    poolPromise = buildPool()
      .then((p) => {
        pool = p;
        return p;
      })
      .catch((err) => {
        // Don't cache a failed resolution forever -- the next call retries
        // from scratch. Required for C4's readyz-degraded evidence: rotate
        // the secret to a bad value, see /readyz flip to 503, fix it, see
        // recovery -- without an app restart in between.
        poolPromise = undefined;
        throw err;
      });
  }
  return poolPromise;
}

// ---------------------------------------------------------------------------
// Readiness check (C4) — a real connectivity probe, not just "did the pool
// object get constructed." Distinguishes the three failure modes C4 names:
// secret failed to resolve, DB unreachable, pool saturated (no free
// connection within the timeout).
// ---------------------------------------------------------------------------
async function checkDbReady() {
  let p;
  try {
    p = await getPool();
  } catch (err) {
    return { ready: false, reason: `secret/pool resolution failed: ${err.message}` };
  }

  let conn;
  try {
    conn = await p.getConnection();
    await conn.ping();
    return { ready: true };
  } catch (err) {
    return { ready: false, reason: `DB unreachable or pool saturated: ${err.message}` };
  } finally {
    if (conn) conn.release();
  }
}

// ---------------------------------------------------------------------------
// MongoDB client (singleton, lazily connected)
// ---------------------------------------------------------------------------
let mongoClient;
let mongoDb;

async function getMongo() {
  if (!mongoDb) {
    mongoClient = new MongoClient(MONGO_URI, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await mongoClient.connect();
    mongoDb = mongoClient.db(MONGO_DB_NAME);
  }
  return mongoDb;
}

// ---------------------------------------------------------------------------
// Graceful shutdown helpers
// ---------------------------------------------------------------------------
async function closeAll() {
  if (pool) {
    try { await pool.end(); } catch (_) { /* ignore */ }
    pool = undefined;
    poolPromise = undefined;
  }
  if (mongoClient) {
    try { await mongoClient.close(); } catch (_) { /* ignore */ }
    mongoClient = undefined;
    mongoDb = undefined;
  }
}

module.exports = {
  MONGO_URI,
  MONGO_DB_NAME,
  getPool,
  getMongo,
  checkDbReady,
  closeAll,
};
