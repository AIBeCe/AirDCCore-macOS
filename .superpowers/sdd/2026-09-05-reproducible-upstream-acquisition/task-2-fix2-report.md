# Task 2 fix round 2 report

## Summary

Reserved `Source/airdcpp-core` with `mkdir` before acquisition, tracked directory and marker inode identities, and performed all Git/cleanup operations from the reserved directory. Cleanup refuses ownership changes and removes the temporary marker on successful publication so the checkout remains clean.

## Files

- `scripts/lib/upstream.sh`: reservation, identity checks, ownership-safe cleanup, marker lifecycle.
- `tests/test_helper.sh`: hermetic publication and marker-preserving replacement wrappers.
- `tests/update_test.sh`: both replacement races, cleanup preservation, and clean-checkout assertion.

## Recovered RED evidence

Command (base implementation copied into a temporary fixture, current race helper/test behavior retained):

```text
rtk sh -c '... git show 61a057ce6f0ad859b93fad2030537b3ad459ae7a:scripts/lib/upstream.sh > "$work/case/scripts/lib/upstream.sh"; ... RACE_MODE=cleanup ... "$work/case/scripts/update" ...'
```

Observed output:

```text
exit=1
update: error: failed to fetch pinned commit 7982e845084b3afab946741da287ab6693093b61 from file:///tmp/airdc-red.I95MJr/fixture/remote.git
```

This is recovered RED evidence: the old staging implementation has no reserved-destination ownership/inode checks and cannot satisfy the new marker-preserving replacement assertion (it reports only generic fetch failure). The fixture was temporary and hermetic; timing of the original interrupted RED run cannot be established.

## GREEN evidence

```text
rtk ./tests/upstream_config_test.sh
PASS: upstream manifest parser
rtk ./tests/update_test.sh
exit 0
rtk git diff --check
exit 0
```

The update suite covers both exact cases: replacement with a copied marker during fetch, and symlink replacement after checkout. Both terminate with `checkout path changed during acquisition`; replacement content/outside targets remain intact.

## Commit

Pending commit for this fix round.

## Self-review and concerns

The reserved directory is the process cwd, so cleanup uses relative globs and only removes the absolute path after rechecking directory and marker identities. POSIX shell has no portable open-directory/rmdir-by-fd primitive; an attacker racing between the final identity check and `rmdir` remains a theoretical limitation. The tested replacement races are rejected before cleanup can remove replacement contents.
