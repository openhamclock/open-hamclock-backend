## Project Completion Status

OHB is and always will be free to use and download. 

OHB serves data from its **own internal services**, not from Clear Sky Institute.

Each supporting file type has a data generation script. These scripts operate on a schedule that is defined in a [crontab](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/crontab). The crontab has been specifically tuned to match as close as possible the original ClearSkyInstitute data generation times and be friendly to CPU/MEM on the host. 

Installers are used to setup, configure and install OHB. We recommend the container-based install as the simplest path go get OHB up and running. See here for [install steps](https://github.com/openhamclock/open-hamclock-backend/blob/main/INSTALL.md)

### Dynamic Text Files
These are replaced dynamically in the background on the target host per the baselined [crontab](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/crontab).

- [x] [Bz/Bz.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/bz_simple.py) - Bz pane
- [x] [aurora/aurora.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_aurora.sh) - Aurora pane
- [x] [xray/xray.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/xray_simple.py) - GOES 16 X-Ray pane
- [x] [worldwx/wx.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_world_wx.pl) - weather display on map hover
- [x] [esats/esats.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/fetch_tle.sh) - supports satellite list under DX
- [x] [solarflux/solarflux-history.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_solarflux-history.sh) - supports solar flux history display when clicking solar flux pane
- [x] [ssn/ssn-history.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_ssn_history.pl) - supports sun spot number history display when clicking sun spot number pane 
- [x] [solar-flux/solarflux-99.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/flux_simple.py) - supports solar flux pane
- [x] [geomag/kindex.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/kindex_simple.py) - supports planetary kp pane
- [x] [dst/dst.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/dst_simple.py) - supports disturbances pane
- [x] [drap/stats.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_drap.sh) - supports drap pane
- [x] [solar-wind/swind-24hr.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/swind_simple.py) - supports solar wind pane
- [x] [ssn/ssn-31.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/ssn_simple.py) - supports (smoothed) sunspot number pane
- [x] [ONTA/onta.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_onta.pl) - generates OTA spots (POTA, SOTA, WWFF) on schedule per crontab
- [x] [contests/contests311.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_contest-calendar.sh) - generates list of recent contests for contests pane
- [x] [dxpeds/dxpeditions.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_dxpeditions_spots.py) - generates list of dxpeds for dxpeds pane
- [x] [NOAASpaceWX/noaaswx.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_noaaswx.sh) - generates NOAA Space Wx metrics for NOAA Space Wx pane
- [x] [cty/cty_wt_mod-ll-dxcc.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/gen_cty_wt_mod.sh) - used to correlate spots for DXCC
      
### Dynamic Map Files
Note: Anything under maps/ is considered a "Core Map" in HamClock

These are replaced dynamically in the background on the target host per the baselined [crontab](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/crontab).

- [x] [maps/Clouds*](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_cloud_maps.sh) - Clouds map display
- [x] maps/Countries* - copied from CSI and hosted locally; no need to regenerate
- [x] [maps/Wx-mB*](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_wx_mb_maps.sh) - Weather map display (millibar)
- [x] [maps/Wx-in*](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_wx_mb_maps.sh) - Weather map display (inches)
- [x] [maps/Aurora](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_aurora_maps.sh) - Aurora map display
- [x] [maps/DRAP*](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_drap_maps.sh) - DRAP map display
- [x] [maps/MUF-RT*](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/kc2g_muf_heatmap.sh) - MUF RT display based on kc2g propagation map engine
- [x] maps/Terrain* - copied from CSI and hosted locally; no need to regenerate; Terrain map display
- [x] [SDO/*](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/update_all_sdo.sh) - images of the Sun for the SDO pane

### Dynamic Web Endpoints
These are endpoints that dynamically return data based on query parameters to the Perl scripts. Query parameters can be 0..Many.

- [x] [ham/HamClock/RSS/web15rss.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/RSS/web15rss.pl) and this [job](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/web15rss_fetch.py) makes the file
- [x] [ham/HamClock/version.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/version.pl)
- [x] [ham/HamClock/wx.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/wx.pl)
- [x] [ham/HamClock/fetchIPGeoloc.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchIPGeoloc.pl) - requires free tier 1000 req per day account and API key
- [x] [ham/HamClock/fetchBandConditions.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchBandConditions.pl) - implemented in a separate container service on same host
- [x] [ham/HamClock/fetchVOACAPArea.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchVOACAPArea.pl) - implemented in a separate container service on same host
- [x] [ham/HamClock/fetchVOACAP-MUF.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchVOACAP-MUF.pl) - implemented in a separate container service on same host
- [x] [ham/HamClock/fetchVOACAP-TOA.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchVOACAP-TOA.pl) - implemented in a separate container service on same host
- [x] [ham/HamClock/fetchPSKReporter.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchPSKReporter.pl) 
- [x] [ham/HamClock/fetchWSPR.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchWSPR.pl)
- [x] [ham/HamClock/fetchRBN.pl](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/fetchRBN.pl)

### Static Files
These files never change or are unlikely to need change any time soon.
- [x] [ham/HamClock/cities2.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/cities2.txt) - we did not update this file as it appears to require no change
- [x] [ham/HamClock/NOAASpaceWx/rank2_coeffs.txt](https://github.com/openhamclock/open-hamclock-backend/blob/main/ham/HamClock/NOAASpaceWX/rank2_coeffs.txt) - we did not update this file as it appears to require no change

### HamClock Upgrades
HamClocks check with the backend for new HamClock versions. When available they attempt to pull the source zip file from the backend to upgrade themselves.

- [x] Upgrades to the latest released HamClock version are supported from v1.0.5. The source file comes from https://github.com/openhamclock/hamclock releases.

### ESP8266-based devices
ESP8266-based devices use an older API (some URLs are different) and need a binary for upgrades rather than source.

- [x] ESP8266-based devices are supported from v1.0.11.

## Integration Testing Status
- [x] GOES-16 X-Ray
- [x] IP Geo Location at startup
- [x] Remote Address Reporting at startup 
- [x] Countries map download and display (all sizes)
- [x] Terrain map download and display (all sizes)
- [x] SDO generation, download, and display
- [x] MUF-RT map generation, download, and display (all sizes)
- [x] Weather map generation, download, and display (all sizes in mB and in)
- [x] Clouds map generation, download, and display (all sizes)
- [x] Aurora map generation, download, and display (all sizes)
- [x] POTA, SOTA, WWFF generation, pull and display
- [x] SSN + history generation, pull, and display
- [x] Solar wind generation, pull and display
- [x] DRAP data generation, pull and display
- [x] Planetary Kp data generation, pull and display
- [x] Solar flux + history data generation, pull and display
- [x] Amateur Satellites data generation, pull and display + [active AMSAT status satellite filter](https://github.com/openhamclock/open-hamclock-backend/blob/main/scripts/filter_amsat_active.pl)
- [x] PSK Reporter WSPR request and display
- [x] PSK Reporter Spots request and display (MQTT based - FAST)
- [x] VOACAP DE DX (uses new docker container)
- [x] VOACAP MUF MAP (REL/TOA) (uses new docker container)
- [x] RBN request and display

