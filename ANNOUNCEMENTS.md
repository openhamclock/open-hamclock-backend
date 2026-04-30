## Announcements

### OHB has a new home!
The original home for OHB (Open Hamclock Backend) has migrated to this repo. You'll find all the commit history in the source. I was one of the contributors and took it over when the former developer chose to move on.

If you are running a version from before the migration, You'll need to jumpstart yourself.

For the docker install, download the latest manage-ohb-docker.sh utility from [Releases](https://github.com/komacke/open-hamclock-backend/releases/latest). Make it executable and simply run an upgrade like before.

If you have a git checkout you need to update your origin like this:
```
# for an https clone:
git remote set-url origin https://github.com/komacke/open-hamclock-backend.git
# for an ssh clone:
git remote set-url origin git@github.com:komacke/open-hamclock-backend.git
```
