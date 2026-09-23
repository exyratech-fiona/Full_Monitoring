# Frontend OpenTelemetry Integration Guide

## Purpose

This guide adds browser telemetry to the static frontend without adding a Java agent to the Nginx container.

The frontend is a compiled JavaScript application served by Nginx. OpenTelemetry must therefore be initialized in the frontend JavaScript before the application starts.

The telemetry flow is:

```text
Browser frontend
    -> same-origin /otel/* endpoint
    -> Nginx proxy
    -> OpenTelemetry Collector :4318 (OTLP HTTP)
    -> Tempo (traces), Prometheus (metrics), Loki (logs)
```

## Important constraints

- Do not use the backend Java agent in the frontend image.
- Do not send browser telemetry directly to `10.102.183.209:4317`.
- Browser applications should use OTLP HTTP on collector port `4318`.
- The telemetry endpoint must be same-origin or exposed through HTTPS with appropriate CORS rules.
- Never send passwords, tokens, authorization headers, request bodies, or personal data as telemetry attributes.

## 1. Install packages

Run the following from the frontend project directory:

```powershell
npm install @opentelemetry/api `
  @opentelemetry/api-logs `
  @opentelemetry/resources `
  @opentelemetry/sdk-trace-web `
  @opentelemetry/sdk-trace-base `
  @opentelemetry/sdk-metrics `
  @opentelemetry/sdk-logs `
  @opentelemetry/exporter-trace-otlp-http `
  @opentelemetry/exporter-metrics-otlp-http `
  @opentelemetry/exporter-logs-otlp-http `
  @opentelemetry/instrumentation `
  @opentelemetry/instrumentation-document-load `
  @opentelemetry/instrumentation-fetch `
  @opentelemetry/instrumentation-xml-http-request
```

For bash/Linux, replace the PowerShell backticks with backslashes or use one line.

## 2. Add the telemetry initialization file

Create `src/telemetry.js` or the equivalent source file:

```javascript
import { WebTracerProvider } from '@opentelemetry/sdk-trace-web';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import {
  MeterProvider,
  PeriodicExportingMetricReader,
} from '@opentelemetry/sdk-metrics';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-http';
import {
  LoggerProvider,
  BatchLogRecordProcessor,
} from '@opentelemetry/sdk-logs';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { logs } from '@opentelemetry/api-logs';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { DocumentLoadInstrumentation } from '@opentelemetry/instrumentation-document-load';
import { FetchInstrumentation } from '@opentelemetry/instrumentation-fetch';
import { XMLHttpRequestInstrumentation } from '@opentelemetry/instrumentation-xml-http-request';

const resource = resourceFromAttributes({
  'service.name': 'Rego_FE_Dev',
  'service.version': '1.0.0',
  'deployment.environment': 'dev',
});

const traceProvider = new WebTracerProvider({ resource });
traceProvider.addSpanProcessor(
  new BatchSpanProcessor(
    new OTLPTraceExporter({ url: '/otel/v1/traces' }),
  ),
);
traceProvider.register();

const metricProvider = new MeterProvider({
  resource,
  readers: [
    new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter({ url: '/otel/v1/metrics' }),
      exportIntervalMillis: 60000,
    }),
  ],
});

const loggerProvider = new LoggerProvider({ resource });
loggerProvider.addLogRecordProcessor(
  new BatchLogRecordProcessor(
    new OTLPLogExporter({ url: '/otel/v1/logs' }),
  ),
);
logs.setGlobalLoggerProvider(loggerProvider);

registerInstrumentations({
  instrumentations: [
    new DocumentLoadInstrumentation(),
    new FetchInstrumentation(),
    new XMLHttpRequestInstrumentation(),
  ],
});

export const tracer = traceProvider.getTracer('rego-frontend');
export const meter = metricProvider.getMeter('rego-frontend');
export const logger = loggerProvider.getLogger('rego-frontend');
```

## 3. Load telemetry before the application

Import telemetry before the frontend's main application entry point.

Example `main.js`, `main.jsx`, or `index.js`:

```javascript
import './telemetry';
import './App';
```

Use the actual application entry point used by the frontend build.

Automatic instrumentation covers:

- Browser document-load traces
- `fetch` requests
- XMLHttpRequests
- Trace context propagation on supported requests

## 4. Optional custom metrics and logs

Automatic browser instrumentation primarily creates traces. Add business or application metrics explicitly where needed:

```javascript
import { meter, logger } from './telemetry';

const pageViews = meter.createCounter('frontend.page_views');
pageViews.add(1, { page: window.location.pathname });

logger.emit({
  severityText: 'INFO',
  body: 'Frontend application loaded',
});
```

Do not record secrets, access tokens, passwords, full query strings, request bodies, or personal information.

## 5. Configure Nginx

Add these locations inside the Nginx `server` block in `nginx.conf`:

```nginx
location = /otel/v1/traces {
    proxy_pass http://otel-collector.monitoring.svc.cluster.local:4318/v1/traces;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

location = /otel/v1/metrics {
    proxy_pass http://otel-collector.monitoring.svc.cluster.local:4318/v1/metrics;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}

location = /otel/v1/logs {
    proxy_pass http://otel-collector.monitoring.svc.cluster.local:4318/v1/logs;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
}
```

The frontend browser sends telemetry to its own domain. Nginx forwards it to the collector inside Kubernetes. This avoids exposing the collector directly to the public internet.

If the frontend is deployed outside the Kubernetes cluster, replace the internal collector address with an HTTPS collector gateway or ingress endpoint. Do not expose an unauthenticated collector service publicly.

## 6. Dockerfile

No Java agent or special runtime variable is required. The existing Dockerfile can remain:

```dockerfile
FROM nginx:1.27-alpine-slim

RUN touch /var/run/nginx.pid
RUN chmod 777 /var/run/nginx.pid

COPY build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
```

The telemetry code must be included in the frontend build before the Docker image is built:

```powershell
npm install
npm run build
docker build -t rego-frontend:1.0.0 .
```

## 7. Kubernetes requirements

The frontend pod must be able to resolve:

```text
otel-collector.monitoring.svc.cluster.local
```

The existing collector Service already exposes:

```text
4317  OTLP gRPC
4318  OTLP HTTP
```

No collector change is required if the existing `otlp` receiver and traces, metrics, and logs pipelines are deployed.

## 8. Verification

After deployment:

1. Open the frontend in a browser.
2. Open browser Developer Tools and select the Network tab.
3. Confirm requests appear for:
   - `/otel/v1/traces`
   - `/otel/v1/metrics`
   - `/otel/v1/logs`
4. Confirm the requests return HTTP `200` or `202`.
5. In Grafana, query Prometheus for:

```promql
{service_name="Rego_FE_Dev"}
```

6. Search Tempo for service `Rego_FE_Dev`.
7. Check the OpenTelemetry Collector logs for rejected exports or dropped data.

## 9. Backend correlation

The backend should continue using:

```text
service.name = Rego_BE_Dev
```

The frontend should use:

```text
service.name = Rego_FE_Dev
```

The browser instrumentation propagates W3C trace context on supported API requests. The backend OpenTelemetry Java agent can then continue the same trace, allowing frontend requests and backend spans to be viewed together in Grafana and Tempo.

## Acceptance criteria

The integration is complete when:

- Frontend builds successfully with the OpenTelemetry packages.
- Nginx proxies the three `/otel/v1/*` paths to collector port `4318`.
- Browser telemetry requests succeed without CORS errors.
- Frontend traces appear in Tempo with `service.name=Rego_FE_Dev`.
- Frontend metrics appear in Prometheus.
- Frontend logs appear in Loki, if logs are enabled.
- Backend API requests preserve the trace relationship with frontend requests.
