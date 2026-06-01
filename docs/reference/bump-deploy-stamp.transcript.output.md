# Bump deploy stamp

Updates `turbo.service.deployStamp` in the in-place codebase. This forces a new
service hash on deploy.

Run in-place so it can update the existing codebase:

``` 
ucm -c ~/.unison/v2 transcript.in-place bump-deploy-stamp.transcript.md
```

``` ucm
scratch/main> load scratch_deploy_stamp.u

  Loading changes detected in scratch_deploy_stamp.u.

  ~ turbo.service.deployStamp : ##Text

  ~ (modified)

  Run `update` to apply these changes to your codebase.

scratch/main> update

  Done.
```
