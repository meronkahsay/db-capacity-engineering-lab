# C5 red-PR (trivy config): deliberately override ingress_cidrs to 0.0.0.0/0.
# This is the exact insecure change the trivy config gate exists to catch --
# see terraform/variables.tf's ingress_cidrs description. Never merge this
# file; the follow-up commit deletes it and shows CI green again.
ingress_cidrs = ["0.0.0.0/0"]
