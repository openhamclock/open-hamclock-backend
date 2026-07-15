## 🚀 Quick Start

Because of recent changes to depend on other docker containers, we recommend the docker install over the native OS install. We are considering a mixed install where the other supporting docker containers are containerized (requiring you run docker) and enable the OHB install to be on your native OS. Input on this appreciated.

### Install in a container with Docker
Download the manager utility that masks all the Docker details. Visit the releases page:

👉 [Releases](https://github.com/openhamclock/open-hamclock-backend/releases/latest)
and download the asset: **Manage Docker installs**.

Make it executable:
```
chmod +x manage-ohb-docker.sh
```

Run it. Substitute the version you want. This installs v0.16:
```
./manage-ohb-docker.sh install -t 0.16
```

### Full Docker Install Instructions
Full docker installation details:
👉 [Detailed Installation Instructions](docker/README.md)

### Install natively on your OS
Clone and run the installer:

```bash
git clone https://github.com/openhamclock/open-hamclock-backend.git
cd open-hamclock-backend
sudo bash install_ohb.sh --size <desired size list>
```
Verify Core Feeds:

```
curl http://localhost/ham/HamClock/solarflux/solarflux-history.txt | tail
curl http://localhost/ham/HamClock/geomag/kindex.txt | tail
```

Verify Maps Exist:
```
sudo ls /opt/hamclock-backend/htdocs/ham/HamClock/maps | head
```

If you see data and maps, OHB is running.

### Full Native Install Instructions
Full installation details:
👉 [Detailed Installation Instructions](INSTALL.md)
