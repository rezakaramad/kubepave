# otel-meta-collector

A small collector with one job: take the **other collectors' own health metrics** and forward them to Mimir. Who watches the watchers? This one.

## Four ways to monitor a collector

| # | How | Catch |
|---|---|---|
| 1 | The collector scrapes itself with its own Prometheus receiver | A loop: if it's stuck, its own metrics can't get out |
| 2 | Prometheus scrapes its port 8888 | Needs a Prometheus, and covers metrics only |
| 3 | The collector pushes straight to the backend | Every collector hits the backend on its own |
| 4 | The collector pushes to a **dedicated collector** | One extra small component |

## Why we chose 4

- **No loop for the other collectors.** They never report through their own pipeline. If a memory limiter starts dropping data, the alarm still gets out.
- **One funnel.** Every collector in a cluster sends to one place, which then makes one connection to the gateway and tags everything with the cluster name.
- **Nothing new to run.** It's just another collector, with no Prometheus to install.

The meta-collector is the **exception**. It sends its own health report to its own OTLP receiver, so it goes out through its normal pipeline and the authenticated gateway exporter. The internal telemetry exporter only takes header values that are read once when the collector starts, so it cannot present the rotating ServiceAccount token itself. The catch is the loop from the table: if the meta-collector's pipeline is stuck, its own report is stuck too, so alert on missing meta-collector metrics.

## Why the meta-collector is different

What matters is where a collector's own metrics go:

- **Other collectors** send them to the meta-collector over plain in-cluster HTTP. Its receiver has no authentication, so the internal telemetry exporter needs no token, only an endpoint.
- **The meta-collector** has nobody to forward its own metrics to except the **gateway**, which requires a ServiceAccount token that rotates. The internal telemetry exporter is built by the OpenTelemetry SDK, not as a pipeline component. It has no `auth` setting and its header values are read once at start, so it cannot present a refreshed token.

## How it's wired

Every other collector in the cluster sends a short report about its own health to the meta-collector once a minute. The meta-collector adds the cluster name and passes the reports on to Mimir through the gateway, as platform data.

Where a collector sends its report is set in its own config, in the `service.telemetry` block of its values file.

## Good to know

- It's one replica. If it's down, the internal metrics pause, but real telemetry keeps flowing. An alert on missing collector metrics would catch it.
- Metric names depend on the method (for example a `_bytes` suffix). Check the real names in Mimir before writing alerts.

Background: Adriana Villela's write-up ["Let's learn how to send internal OTel Collector telemetry to an observability backend"](https://medium.com/womenintechnology/lets-learn-how-to-send-internal-otel-collector-telemetry-to-an-observability-backend-9aef6a18f317).

You can read more about internal telemetry [here](https://opentelemetry.io/docs/collector/internal-telemetry).
