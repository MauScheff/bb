# Bump deploy stamp

Updates `turbo.service.deployStamp` in the in-place codebase. This forces a new
service hash on deploy.

`just bump-deploy-stamp` no longer uses this transcript. The current path is a
scripted UCM session that starts directly in `turbo/main`, then runs:

```text
load scratch_deploy_stamp.u
update
quit
```

If you need to do it manually, use:

```
printf "load scratch_deploy_stamp.u\nupdate\nquit\n" | \
  direnv exec . ucm -p turbo/main
```
