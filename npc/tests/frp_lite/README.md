# FRP-Lite directed regression

Run with a configuration that enables `CONFIG_BRANCH_FAST_RECURRENCE`:

```sh
make
```

The test covers same-group ANDI/branch, non-adjacent register-token matching,
x0 in either branch source position, invalidation by a younger register write,
the XPERM4 load-pair shape, recurrence activation, and boundary resynchronization.
