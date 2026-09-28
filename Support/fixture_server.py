"""Deterministic UI-test server. Synthetic data is never included in the app target.

Run: python3 weatheratlas-ios/Support/fixture_server.py
Bind to loopback only. All app test requests remain on this server.
"""
import json
import math
import os
import struct
import threading
import time as clock
import zlib
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

NOW = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
PLAYBACK_EVENTS = []
PLAYBACK_LOCK = threading.Lock()
FORECAST_DELAY = 0.0
CATALOGUE_DELAY = 0.0
FORECAST_EVENTS = []
# Explicit gates make refresh-layout tests deterministic without waiting five minutes.
FORECAST_GATES = {stage: threading.Event() for stage in ("bulletin", "optional")}
for forecast_gate in FORECAST_GATES.values():
    forecast_gate.set()
FORECAST_TEMPERATURE_OFFSET = 0.0


def time(hours=0):
    return (NOW + timedelta(hours=hours)).isoformat().replace("+00:00", "Z")


def tile():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + bytes([20, 160, 180, 90]) * 256 for _ in range(256))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


PALETTE = [{"value": 0, "color": "#166bba"}, {"value": 20, "color": "#19aaa0"}, {"value": 40, "color": "#f6b94f"}]
FRAME = dict(validTime=time(), runTime=time(-6), forecastHour=6,
             intervalStart=None, intervalEnd=None, timeKind="instant")
REGION = dict(id="0123456789abcdef", name="Halifax Metro", latitude=44.65, longitude=-63.57,
              province="NS", provinceName="Nova Scotia", issuedAt=time(-1), stale=False,
              periods=[dict(name=["Today", "Tonight", "Tuesday", "Tuesday night", "Wednesday", "Wednesday night", "Thursday"][i],
                            start=time(12*i), end=time(12*(i+1)), temperatureC=22 if i % 2 == 0 else 14,
                            temperatureClass="high" if i % 2 == 0 else "low", relativeHumidityPercent=65,
                            popPercent=0 if i == 3 else None if i in (0, 4, 5) else 30,
                            precipitationAmount="5 to 10 mm" if i == 0 else None,
                            condition=["Periods of rain.", "Partly cloudy.", "Cloudy.", "Clear.",
                                       "Snow.", "Rain mixed with snow.", "Chance of thunderstorms."][i])
                       for i in range(7)])
SECOND_REGION = {**REGION, "id": "sydney-fixture", "name": "Sydney", "latitude": 46.14, "longitude": -60.19}
# Exercise country-scale decoding and picker rendering, not only two tiny regions.
REGIONS = [REGION, SECOND_REGION] + [
    {**REGION, "id": f"test-region-{i}", "name": f"Test region {i}",
     "province": "ON", "provinceName": "Ontario", "latitude": 44 + (i % 12) * 0.2,
     "longitude": -81 + (i % 36) * 0.1} for i in range(639)
]
STATION = dict(id="CAAW", name="Shearwater", latitude=44.64, longitude=-63.51,
               source="MSC", attribution="Synthetic observation fixture", distanceKm=4.6, stale=False,
               observation=dict(observedAt=time(), expiresAt=time(2), expectedIntervalMinutes=60,
                                values=dict(temperatureC=14.5, windKmh=12, precipitationMm=None),
                                quality=dict(precipitationMm=dict(state="trace", sourceField="pcpn_amt_pst1hr", unit="mm")),
                                intervals={}))


def golf_fixture(query):
    """Synthetic, deterministic presentation data; never a production weather calculation."""
    def param(key, default):
        return query.get(key, [default])[0]
    zone = ZoneInfo(param("time_zone", "America/Halifax"))
    start = datetime.fromisoformat(param("local_date", "2026-09-16") + "T" + param("tee_time", "10:00")).replace(tzinfo=zone)
    limits = {key: float(param(query_key, str(value))) for key, query_key, value in [
        ("minTemperatureC", "min_temperature_c", 8), ("maxTemperatureC", "max_temperature_c", 30),
        ("maxWindKmh", "max_wind_kmh", 25), ("maxRainMm", "max_rain_mm", 1),
        ("maxPopPercent", "max_pop_percent", 40)]}
    days = []
    for offset in range(7):
        tee = (start + timedelta(days=offset)).astimezone(timezone.utc)
        def at(hours):
            return (tee + timedelta(hours=hours)).isoformat().replace("+00:00", "Z")
        state = ["within", "outside", "within", "incomplete"][offset % 4]
        wind = 40 if state == "outside" else 10
        pop = None if offset % 4 in (0, 2, 3) else 10
        parts = [dict(name=name, start=at(a), end=at(b), temperatureRangeC=[18, 20],
                      maxWindKmh=None if state == "incomplete" else wind, maxGustKmh=wind + 10, popPercent=pop,
                      rain=dict(minimumMm=0.125*(b-a), maximumMm=0.125*(b-a), coverStart=at(a), coverEnd=at(b)),
                      rainTimingUncertain=False,
                      checks=[dict(field=f, label=f, state="outside" if f == "wind" and state == "outside" else "not_provided" if f == "pop" and pop is None else "unknown" if f == "wind" and state == "incomplete" else "within", fit=None if (f == "pop" and pop is None) or (f == "wind" and state == "incomplete") else 80)
                              for f in ("temperature", "wind", "rain", "pop")])
                 for name, a, b in [("Before", -2, 0), ("Round", 0, 4), ("After", 4, 5)]]
        days.append(dict(date=(start + timedelta(days=offset)).date().isoformat(), teeTime=at(0), endTime=at(4),
                         state=state, score={"within": 80, "outside": 30, "incomplete": None}[state], segments=parts,
                         scoreCoverage="none" if state == "incomplete" else "complete",
                         probabilityNote=None,
                         reasons=[], briefingDetail=("Sustained wind falls outside your limits before, during and after the round." if state == "outside" else "Sustained wind cannot be fully assessed before, during and after the round." if state == "incomplete" else "Temperature, sustained wind and precipitation meet your preferences before, during and after the round."),
                         modelRows=[dict(time=at(h), temperatureC=20, windKmh=wind, gustKmh=wind+10) for h in range(-2, 6)],
                         precipitationIntervals=[dict(start=at(h-1), end=at(h), field="total_precipitation_1h", mm=0.125) for h in range(-1, 6)],
                         regionalPeriods=[dict(name="Day", start=at(-6), end=at(6), temperatureC=20, temperatureClass="high", popPercent=pop, condition="Rain")],
                         contentID=f"fixture-{offset}-{limits}-{tee.isoformat()}"))
    return dict(generatedAt=time(), ruleVersion="golf-fit-v3", latitude=float(param("latitude", "44.65")),
                longitude=float(param("longitude", "-63.57")), timeZone=zone.key, source="Synthetic GDPS fixture",
                runTime=time(-2), limits=limits, regionalContext=dict(name="Halifax", distanceKm=2, issuedAt=time(-1), stale=False),
                method="Synthetic test data. Model-grid point sample; precipitation is not prorated. Regional PoP is not a point probability.",
                scoreMeaning="Weather-fit index, not a probability or safety guarantee. Missing required data means no score.", days=days)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global FORECAST_DELAY, CATALOGUE_DELAY, FORECAST_TEMPERATURE_OFFSET
        parsed = urlparse(self.path)
        path, query = parsed.path, parse_qs(parsed.query)
        if path == "/test/forecast-refresh":
            if query.get("reset") == ["1"]:
                for gate in FORECAST_GATES.values():
                    gate.set()
                FORECAST_TEMPERATURE_OFFSET = 0.0
            for stage in query.get("hold", []):
                FORECAST_GATES[stage].clear()
            for stage in query.get("release", []):
                FORECAST_GATES[stage].set()
            if "temperature_offset" in query:
                FORECAST_TEMPERATURE_OFFSET = float(query["temperature_offset"][0])
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b"{}")
            return
        if path == "/test/startup":
            if "catalogue_delay" in query:
                CATALOGUE_DELAY = max(0.0, min(10.0, float(query["catalogue_delay"][0])))
            with PLAYBACK_LOCK:
                if query.get("reset") == ["1"]:
                    FORECAST_EVENTS.clear()
                body = json.dumps(FORECAST_EVENTS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith("/api/"):
            with PLAYBACK_LOCK:
                FORECAST_EVENTS.append(dict(path=path, at=clock.monotonic()))
        if path == "/test/forecast-delay":
            FORECAST_DELAY = max(0.0, min(10.0, float(query.get("seconds", ["0"])[0])))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"delay": FORECAST_DELAY}).encode())
            return
        if path.startswith("/api/v1/forecast/"):
            stage = "optional" if path.endswith(("/hourly", "/precipitation")) else "bulletin"
            FORECAST_GATES[stage].wait(timeout=30)
            clock.sleep(FORECAST_DELAY)
        if path == "/test/playback-events":
            with PLAYBACK_LOCK:
                if query.get("reset") == ["1"]:
                    PLAYBACK_EVENTS.clear()
                body = json.dumps(PLAYBACK_EVENTS).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        if path.startswith("/tiles/"):
            frame = path.split("/")[3] if path.startswith("/tiles/model/") else None
            with PLAYBACK_LOCK:
                PLAYBACK_EVENTS.append(dict(frame=frame, event="requested", at=clock.monotonic()))
            if frame == "1":
                clock.sleep(float(os.environ.get("WEATHER_TEST_SLOW_TILE_SECONDS", "0")))
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(tile())
            with PLAYBACK_LOCK:
                PLAYBACK_EVENTS.append(dict(frame=frame, event="sent", at=clock.monotonic()))
            return
        data = None
        if path == "/api/v1/products":
            # Research products deliberately sort first, like a newly added custom run.
            data = {"items": [dict(code=code, name=code.upper(), description="Fixture model", kind="forecast", priority=i+1, latestRunTime=time(-6)) for i, code in enumerate(["flexpart_smoke", "custom_run_123", "hrdps", "gdps"])]}
        elif path.endswith("/domains"):
            data = {"items": [dict(code="continental", name="Canada", bounds=[-140, 40, -40, 80])]}
        elif path.endswith("/fields"):
            temperature = dict(code="air_temperature_2m", variableCode="air_temperature", name="Temperature",
                                  variableClass="atmosphere", levelCode="2m_agl", levelName="2 m", unit="degC",
                                  palette=PALETTE, defaultMin=0, defaultMax=40)
            data = {"items": [temperature] + [
                {**temperature, "code": code, "variableCode": variable, "name": name, "unit": unit}
                for code, variable, name, unit in [
                    ("wind_u_10m", "wind_u", "Eastward wind component", "m/s"),
                    ("relative_humidity_2m", "relative_humidity", "Relative humidity", "%"),
                    ("wind_v_10m", "wind_v", "Northward wind component", "m/s"),
                    ("total_cloud_cover", "total_cloud_cover", "Total cloud cover", "%"),
                    ("total_precipitation_1h", "precipitation", "Total precipitation", "mm"),
                ]
            ]}
            if any(code in path for code in ("flexpart_smoke", "custom_run_123")):
                data["items"].append({**temperature, "code": "wildfire_pm25_surface",
                                      "variableCode": "wildfire_pm25", "name": "Research smoke", "unit": "ug/m3"})
        elif path.endswith("/timeline"):
            data = {"items": [{**FRAME, "validTime": time(i), "forecastHour": 6+i} for i in range(12)], "truncated": False}
        elif path == "/api/v1/layers/resolve":
            valid = query.get("valid_time", [time()])[0]
            field = query.get("field", ["air_temperature_2m"])[0]
            index = round((datetime.fromisoformat(valid.replace("Z", "+00:00")) - NOW).total_seconds() / 3600)
            data = dict(product=query.get("product", ["hrdps"])[0], domain="continental", runTime=time(-6), validTime=valid,
                        forecastHour=6, field=field, variable="air_temperature" if field == "air_temperature_2m" else field,
                        level="2m_agl", unit="degC", tileUrl=f"/tiles/model/{index}/{{z}}/{{x}}/{{y}}.png",
                        token=valid, bounds=[-140,40,-40,80], legend=dict(minimum=0, maximum=40, palette=PALETTE))
        elif path == "/api/v1/golf/outlook":
            data = golf_fixture(query)
        elif path == "/api/v1/forecast/changes":
            change = dict(id="temperature-change", field="temperatureC", start=time(), end=time(12),
                          before=19, after=22, delta=3, unit="°C", summary="Temperature: 19 → 22 °C")
            data = dict(regionId=query.get("area_id", [REGION["id"]])[0], generatedAt=time(), stale=False,
                        groups=[dict(source="ECCC regional bulletin", state="changed", currentIssuedAt=time(-1),
                                     previousIssuedAt=time(-7), matchedPeriods=6, comparableValues=12,
                                     highlights=[change], details=[change])])
            if query.get("include_forecasts") == ["true"]:
                current = next((r for r in REGIONS if r["id"] == data["regionId"]), REGION)
                previous = {**current, "issuedAt": time(-7), "periods": [
                    {**period, "condition": "Sunny." if i == 0 else period["condition"],
                     "precipitationAmount": None if i == 0 else period["precipitationAmount"]}
                    for i, period in enumerate(current["periods"])]}
                data["bulletins"] = dict(state="ready", current=current, previous=previous,
                    assessment="candidate_changes", importantFacts=[
                        f"Conditions {current['periods'][0]['start']} to {current['periods'][0]['end']}: "
                        f"PREVIOUS Sunny; CURRENT {current['periods'][0]['condition']}."])
        elif path in ("/api/v1/observations/nearby", "/api/v1/observations/stations"):
            data = dict(generatedAt=time(), items=[STATION], nextOffset=None)
        elif path == "/api/v1/observations/stations/CAAW/history":
            data = dict(stationId="CAAW", field=query.get("field", ["temperatureC"])[0],
                        items=[dict(time=time(-i), value=14+i/10 if i != 3 else None) for i in range(48)])
        elif path == "/api/v1/widgets/forecast":
            data = dict(schemaVersion=1, regionId=query.get("area_id", [REGION["id"]])[0], name="Halifax Metro",
                        source="Synthetic forecast fixture", issuedAt=time(-1), generatedAt=time(),
                        expiresAt=time(12), nextRefreshAt=time(1), entries=[
                            dict(date=time(i), validUntil=time(i+1), temperatureC=20+i/10,
                                 highC=22, lowC=14, condition="Partly cloudy", symbol="cloud.sun.fill",
                                 popPercent=30, precipitationMm=None, hours=[]) for i in range(12)])
        elif path == "/api/v1/forecast/regions":
            clock.sleep(CATALOGUE_DELAY)
            data = dict(generatedAt=time(), timeZone="America/Halifax", regions=REGIONS)
        elif path == "/api/v1/forecast/nearest":
            region = SECOND_REGION if float(query.get("latitude", ["44.65"])[0]) > 45.5 else REGION
            data = dict(region=region, distanceKm=2.5, matchKind="nearest_representative_point")
        elif path == "/api/v1/hotspots/dates":
            data = {"items": [{"dataDate": NOW.date().isoformat()}]}
        elif path == "/api/v1/hotspots":
            data = {"features": [
                {"geometry": {"coordinates": [-63.6, 44.7]}, "properties": {"observed_at": time(), "sensor": "VIIRS"}}]}
        elif path == "/api/v1/wind-vectors":
            data = {"unit": "m/s", "features": [
                {"geometry": {"coordinates": [-63.9+i*0.15, 44.3+i*0.12]}, "properties": {"speed": 10, "bearing": 45}}
                for i in range(8)]}
        elif path == "/api/v1/sample":
            data = dict(latitude=44.65, longitude=-63.57, runTime=time(-6), validTime=time(), values=[
                dict(field="air_temperature_2m", variable="air_temperature", level="2m_agl", value=22, unit="degC", nodata=False)])
        elif path == "/api/v1/forecast/hourly":
            data = dict(regionId=query.get("area_id", [REGION["id"]])[0], source="ECCC GDPS", generatedAt=time(), start=time(), end=time(72),
                        availableHours=71, completeHours=71, hours=[
                            dict(time=time(i), runTime=time(-6), precipitationStart=time(i-1),
                                 status="missing" if i==5 else "complete", temperatureC=None if i==5 else round(18+5*math.sin(i/6), 1),
                                 relativeHumidityPercent=None if i==5 else round(65+10*math.sin(i/8)),
                                 precipitationMm=None if i==5 else 1.6 if i % 11 == 0 else 0,
                                 windKmh=None if i==5 else round(18+5*math.sin(i/12)),
                                 gustKmh=None if i==5 else round(28+5*math.sin(i/12)))
                            for i in range(72)])
        elif path == "/api/v1/forecast/precipitation":
            data = dict(regionId=query.get("area_id", [REGION["id"]])[0], issuedAt=REGION["issuedAt"],
                        source="ECCC GDPS", generatedAt=time(), periods=[
                            dict(start=period["start"], end=period["end"],
                                 status="official" if i == 0 else "missing" if i == 2 else "complete",
                                 precipitationMm=None if i in (0, 2) else 0 if i == 3 else 0.05 if i == 4 else 2.4,
                                 runTime=None if i in (0, 2) else time(-6))
                            for i, period in enumerate(REGION["periods"])])
        elif path == "/api/v1/imagery":
            data = {"items": [
                dict(code=code, name=name, kind=kind, attribution="UI test fixture · synthetic imagery", stale=False,
                     frames=[dict(id=f"{code}-{i}", validTime=time(-1+i/6), tileUrl="/tiles/fixture/{z}/{x}/{y}.png",
                                  bounds=[-69,41,-52,50]) for i in range(6)])
                for code, name, kind in [("radar_rain", "Radar · rain rate", "radar"), ("satellite_natural", "Satellite · natural colour", "satellite")]]}
        if data is not None and path.startswith("/api/v1/forecast/") and FORECAST_TEMPERATURE_OFFSET:
            # Copy the synthetic response, never mutate shared region fixtures.
            data = json.loads(json.dumps(data))
            periods = data.get("hours", [])
            if "region" in data:
                periods += data["region"]["periods"]
            for region in data.get("regions", []):
                periods += region["periods"]
            for period in periods:
                if period.get("temperatureC") is not None:
                    period["temperatureC"] += FORECAST_TEMPERATURE_OFFSET
        self.send_response(200 if data is not None else 404)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps(data if data is not None else {"detail": "No fixture route"}).encode())


if __name__ == "__main__":
    print("Weather Atlas UI fixtures: http://localhost:8097", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8097), Handler).serve_forever()
