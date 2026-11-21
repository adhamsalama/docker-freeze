# docker-freeze

Experiment: free a container's RAM without losing its in-memory state by
checkpointing it to disk with CRIU, then restoring it later.

```sh
# freeze
docker checkpoint create <c> freeze-<c>
# unfreeze
docker start --checkpoint freeze-<c> <c>
docker checkpoint rm <c> freeze-<c>
```

`freeze-test.sh` runs this against a MongoDB container, loads some data,
and reports host memory before, while frozen, and after restore. It also
checks that runtime-only state survived. The GitHub Actions workflow
installs CRIU, enables Docker's experimental mode, and runs the script.
The results appear in the job log and the run summary.
