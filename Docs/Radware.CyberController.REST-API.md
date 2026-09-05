# Radware Cyber Controller (APSolute Vision) - REST API summary

Cyber Controller is the current name of the product that used to be called
**APSolute Vision**. The management REST API kept the same `/mgmt/...` URL space,
so the APSolute Vision REST API reference guides are the authoritative
documentation for the Cyber Controller API as well.

## Where the official documentation lives

| Document | URL |
|---|---|
| APSolute Vision / Cyber Controller REST API reference (per version) | `https://webhelp.radware.com/vision/REST/<version>/index.html` - e.g. [5.1](https://webhelp.radware.com/vision/REST/5_1_0/index.html), [4.83](https://webhelp.radware.com/vision/REST/4_83_00/index.html), [4.40](https://webhelp.radware.com/Vision/REST/4_40_00/index.html) |
| Same reference served by the appliance itself | `https://<CYBER_CONTROLLER_IP>/webhelp/` (REST API section) |
| "APSolute Vision REST API" support answer | https://support.radware.com/app/answers/answer_view/a_id/18080/ |
| "How to run REST API commands to Vision using RestLet Client" (login walkthrough) | https://support.radware.com/app/answers/answer_view/a_id/1016138/ |
| "How to get security and operational alerts via REST API" | https://support.radware.com/app/answers/answer_view/a_id/1020047/ |
| Automation using the REST API (release notes) | https://portals.radware.com/releasenotes/APSolute_Vision_Release_Notes_4_81_01/APSolute_Vision_Release_Notes/APSoluteVision_4.81.01_RN.1.36.html |
| DefenseFlow REST API (separate product, separate API) | https://webhelp.radware.com/DefenseFlow/REST/4_00_00/index.html |
| Cloud DDoS REST API (SaaS, uses API keys, not JSESSIONID) | https://portals.radware.com/ProductDocumentation/Cloud_DDoS_REST_API/ |

Always confirm the endpoint list against the reference guide that matches **your**
installed version - endpoints outside the login/logout core do change between
releases.

## Transport and conventions

* Base URL: `https://<CYBER_CONTROLLER_IP>` (HTTPS, port 443). The appliance ships
  with a self-signed certificate, so either import it into the trust store or
  explicitly skip validation in the client.
* `Content-Type: application/json` on every request that has a body.
* All management endpoints live under `/mgmt/`.
* Authentication is **session based**: log in once, then send the returned
  `JSESSIONID` on every subsequent call.
* Responses are JSON and usually carry a `status` field (`ok` / `error`) plus a
  `message` on failure. HTTP 200 with `"status":"error"` is common, so check the
  body, not only the status code.

## Authentication

### Login

```
POST https://<CYBER_CONTROLLER_IP>/mgmt/system/user/login
Content-Type: application/json

{ "username": "<user>", "password": "<password>" }
```

Documented curl form:

```bash
curl -k -X POST -H "Content-Type: application/json" \
     https://VISION_IP/mgmt/system/user/login \
     -d '{"username":"VISION_USER","password":"VISION_PASSWORD"}'
```

The response contains the session id, e.g.

```json
{ "status": "ok", "jsessionid": "FC90B1D581A7F9735372B9286F1B57D6" }
```

The same value is also returned as a `JSESSIONID` cookie.

### Using the session

Every following request must carry the session id in the `Cookie` header:

```
Cookie: JSESSIONID=FC90B1D581A7F9735372B9286F1B57D6
```

### Logout

```
GET https://<CYBER_CONTROLLER_IP>/mgmt/system/user/logout
Cookie: JSESSIONID=<session id>
```

Sessions also expire on the server side after the configured idle timeout, and
each user has a limited number of concurrent sessions - always log out when a
script finishes so sessions are not leaked.

## Frequently used endpoint families

| Purpose | Endpoint |
|---|---|
| Login / logout | `POST /mgmt/system/user/login`, `GET /mgmt/system/user/logout` |
| Managed device inventory | `GET /mgmt/system/config/itemlist/alldevices` |
| Per-device operations (by IP) | `/mgmt/device/byip/<device-ip>/...` (e.g. `.../monitor` for uptime/health) |
| DefensePro configuration tree | `/mgmt/device/byip/<device-ip>/config/...` |
| Traffic utilization report | `POST /mgmt/monitor/security/dp/traffic/utilization/table` |
| Alerts (Alert Browser content) | `/mgmt/system/alerts/...` reporting endpoints - see the "security and operational alerts" support answer above |

Endpoint names differ per version; the two authentication endpoints are the
stable part of the API and are what `Scripts/Radware.CyberController.Connect.ps1`
implements.

## Permissions

Use a dedicated API account. Read-only automation works well with a *Reporter* /
read-only role; configuration changes require an administrator role. Note that
lockout and password policies apply to API logins exactly as they do to the UI,
so a script that retries a wrong password can lock the account.
