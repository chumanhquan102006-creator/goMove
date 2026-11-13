# M2A weather pricing

Weather pricing is an optional, server-side academic demonstration signal. It is disabled by default; enable it with `GOMOVE_WEATHER_PRICING_ENABLED=true` only in a deliberate test/demo environment. Flutter requests cannot provide weather, multiplier, or pricing timestamps.

## Provider and observation meaning

The initial adapter uses the fixed HTTPS Open-Meteo Forecast API host `api.open-meteo.com`. It requests current `rain`, in millimetres, with `timeformat=unixtime` and `timezone=UTC`. It accepts the provider's `UTC` or `GMT` timezone name only when `utc_offset_seconds=0`, then validates the documented 900-second interval and `mm` unit. Open-Meteo current conditions are model-based estimates, not guaranteed physical measurements; the returned interval describes the period represented by the value. Observations more than the configured 30 minutes old, from the future, malformed, or in an unsupported unit/interval do not raise the fare.

The demonstration policy treats rain below 0.2 mm as `NO_RAIN`, from 0.2 mm to below 2.0 mm as `RAIN` (1.10), and 2.0 mm or more as `HEAVY_RAIN` (1.15). Provider failure, stale data, invalid data, and a disabled feature use multiplier 1.0000 with distinct snapshot reason/status values. These values are configurable academic examples, not commercial pricing recommendations.

Nearby coordinates are rounded to a 0.01-degree grid before the provider request and an in-memory SHA-256 key is used for caching. Successful data is cached for two minutes and failures for ten seconds, with a 256-entry LRU bound. No exact coordinate or cache key is logged. The adapter has explicit connect/read timeouts, no retries, and an 8 KiB response-body limit.

The immutable pricing snapshot separates the observation and policy decision from the monetary effect:

- `weatherRainMm`, `weatherDataStatus`, and `weatherReason` record the observation classification and its reason. Rain detected by the policy does not by itself mean a surcharge reached the fare.
- `configuredWeatherMultiplier` and `requestedWeatherMultiplier` are the factor selected by the weather policy; the legacy `weatherMultiplier` field is an alias for the same requested factor. The configured rain and heavy-rain factors remain separately recorded as `configuredRainMultiplier` and `configuredHeavyRainMultiplier`. None of these requested values is the actual applied weather uplift. `weatherPolicyApplied` preserves the policy's rain-classification decision.
- `preWeatherMultiplier` is the tariff × peak multiplier before weather, `rawWeatherAdjustedMultiplier` is the unrounded requested composition, and `finalEffectiveMultiplier` is the actual multiplier used by the fare calculation. `actualMultiplierUplift` is the exact scale-4 decimal delta `finalEffectiveMultiplier - preWeatherMultiplier`. `weatherApplied` is true only when that actual delta is positive.
- `weatherUpliftStatus` is `NO_UPLIFT_REQUESTED`, `FULLY_APPLIED`, `PARTIALLY_CAPPED`, or `FULLY_SUPPRESSED_BY_CAP`. `FULLY_APPLIED` means the rounded requested combined multiplier was used without cap constraint; the exact surviving delta remains in `actualMultiplierUplift`. `totalSurgeCapApplied` says whether the requested weather uplift was constrained by the combined cap. If the tariff × peak baseline is already at or above the cap, the weather uplift is fully suppressed and the baseline remains intact.
- `actualWeatherFareDifferenceVnd` is an audit-only comparison: final VND fare minus the fare from the same raw tariff, route, peak multiplier and discount inputs without weather, with each result rounded using the existing whole-VND HALF_UP rule. A positive multiplier delta may still have a `0.00` VND difference when whole-VND rounding removes it. This field does not add a fare line or change customer pricing.

The existing fare components and reconciliation remain unchanged. In particular, `effectiveSurgeMultiplier` keeps its M1 meaning of tariff × peak before weather. Quote/Booking prices and their complete snapshots remain immutable after creation, including after later policy configuration changes. The combined cap constrains only the incremental weather uplift; it must never reduce an already higher tariff × peak price.

## Attribution and usage

Provider attribution: [Weather data by Open-Meteo.com](https://open-meteo.com/). Open-Meteo data is provided under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); retain attribution and license information when redistributing or displaying derived weather data. The current mobile API does not display the weather observation itself. Recheck provider terms and rate limits before any non-academic or commercial use; no paid API credentials are configured by this milestone.
