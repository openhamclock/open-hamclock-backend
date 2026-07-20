<!--
  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU Affero General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU Affero General Public License for more details.

  You should have received a copy of the GNU Affero General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
-->

## Install:

Because of recent changes to depend on other docker containers, we recommend the docker install over the native OS install. We are considering a mixed install where the other supporting docker containers are containerized (requiring you run docker) and enable the OHB install to be on your native OS. Input on this appreciated.

(NOTE: to run OHB in docker, visit [the Docker instructions](docker/README.md))

## The the install:

```bash
   # Confirmed working in aws t3-micro Ubuntu 24.x LTS instance
   wget -O install_ohb.sh https://raw.githubusercontent.com/openhamclock/open-hamclock-backend/refs/heads/main/aws/install_ohb.sh
   chmod +x install_ohb.sh
   sudo ./install_ohb.sh
```
## Selecting map image sizes during install

By default, OHB generates the full HamClock size set. This is only recommend on a high end PC or VM:

`660x330,1320x660,1980x990,2640x1320,3960x1980,5280x2640,5940x2970,7920x3960`

To install with a custom size set, pass one of the options below:

### Option A: Comma-separated list
> [!WARNING]
> Attempting to image generate multiple sizes or 4K UHD sizes on Pi3B can cause it to overheat!

```bash
chmod +x ./install_ohb.sh
sudo ./install_ohb.sh --sizes "660x330,1320x660,1980x990"
```
### Option B: Repeat --size
> [!WARNING]
> Attempting to image generate multiple sizes or 4K UHD sizes on Pi3B can cause it to overheat!

```bash
chmod +x ./install_ohb.sh
sudo ./install_ohb.sh --size 660x330 --size 1320x660 --size 1980x990
```

Install script will store configuration under /opt/hamclock-backend/etc/ohb-sizes.conf

```bash
# Canonical default list (keep in sync with HamClock)
DEFAULT_SIZES=( \
  "660x330" \
  "1320x660" \
  "1980x990" \
  "2640x1320" \
  "3960x1980" \
  "5280x2640" \
  "5940x2970" \
  "7920x3960" \
)
```

Note: OHB will install default maps (Countries and Terrain) for all possible sizes. This does not incur any major CPU or RAM hit on small form factor PCs as it is just a download, extract and install

After install, update your HamClock startup script to point to OHB. Then, reboot your HamClock.

## Starting HamClock with OHB Local Install
HamClock is hard-coded to use the clearskyinstitute.com URL. You can override to use a new backend by starting HamClock with the -b option

### Localhost (if running OHB adjacent to your existing HamClock client such as Raspberry Pi)
```bash
hamclock -b localhost:80
```
Note: Depending on where you installed HamClock application, the path may be different. If you followed the instructions [here](https://qso365.co.uk/2024/05/how-to-set-up-a-hamclock-for-your-shack/), then it will be installed in /usr/local/bin.

### Starting HamClock with OHB Central Install
```bash
hamclock -b \<central-server-ip-or-host\>:80
```
## Stopping OHB
### Web Server
```bash
sudo systemctl stop lighttpd
```
### Cron Jobs
#### Remove all jobs
```bash
sudo crontab -u www-data -l > ~/www-data.cron.backup
sudo crontab -u www-data -r
```
Note: Removing the cron jobs will stop all future background processes, not currently running. Ensure that the www-data.cron.backup actually was created before you remove all of www-data user's cronjobs

#### Restore all jobs
```bash
sudo crontab -u www-data /path/to/www-data.cron.backup
sudo crontab -u www-data -l | head
```

### API Keys
Two services require API keys: openweathermaps.com and ipgeolocation.io.

If openweathermaps doesn't get a key, HamClock will fall back to open-meteo.com. If ipgeolocation.io doesn't have a key, installing a new HamCLock won't be able to pull up your location. Not the end of the world.

If you have these keys, you can provide them to OHB by putting them into /opt/hamclock-backend/.env and formatting the contents like this:
```
# for the api.openweathermap.org API
OPEN_WEATHER_API_KEY=<insert key here>

# for the app.ipgeolocation.io API
IPGEOLOC_API_KEY=<insert key here>

# for api.timezonedb.com which computes DST
TIMEZONEDB_API_KEY=<insert key here>

# for WWFF spots that are pulled from cqgma.org
CQGMA_API_KEY=<insert key here>
```
Replace \<insert key here\> with your respective key.

Restart lighttpd after creating or modifying this file.
