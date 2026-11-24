# Devbox deployment

This directory contains the pull-based deployment used by the private Devbox host.
GitHub Actions only merges the public upstream into this fork; the internal Devbox
polls the fork, builds a candidate image, and switches containers after the image
and health checks pass.

Install `dsh-superagent-update.service` and `dsh-superagent-update.timer` as user
units, adjusting `WorkingDirectory` if the checkout is not at
`/home/chaichunyan/dsh-superagent/superagent-src`. The timer invokes
`deploy-devbox.sh` every ten minutes. The script serializes runs, refuses dirty or
diverged checkouts, and never force-pushes or resolves merge conflicts.

The deploy-specific `Dockerfile`, `compose.yml`, and persistent `data/` directory
remain on the Devbox host and are intentionally not part of this prototype fork.
The host deployment script writes `superagent-src/.source-commit` for the image
build, updates the Compose image tag, retains the previous image as a rollback
tag, and restores the previous checkout and container if health does not become
healthy. A failed or timed-out GitHub fetch leaves the current deployment
untouched and is retried by the next timer run.

Useful commands:

```sh
systemctl --user status dsh-superagent-update.timer
journalctl --user -u dsh-superagent-update.service
systemctl --user start dsh-superagent-update.service
```
