"""Instructor dashboard. All dynamic text is escaped before insertion."""
from html import escape
from urllib.parse import quote


def button(path, csrf, label, style=""):
    return (f'<form method="post" action="{escape(path)}">'
            f'<input type="hidden" name="csrf_token" value="{escape(csrf)}">'
            f'<button class="{style}">{escape(label)}</button></form>')


def enrollment_card(row, csrf):
    path = f'/admin/enrollments/{quote(row["id"], safe="")}'
    state = row["status"]
    actions = []
    if state == "pending":
        actions += [("approve", "Approve", "primary"), ("reject", "Reject", "")]
    elif state == "approved":
        actions.append(("revoke", "Revoke", ""))
    if row["available"] and (state != "approved" or row["provisioned_at"] is not None):
        actions.append(("delete", "Remove photo", ""))
    picture = (f'<a href="{path}/image"><img src="{path}/image" alt="Enrollment photo" loading="lazy"></a>'
               if row["available"] else '<div class="avatar" aria-hidden="true">◎</div>')
    controls = "".join(button(f"{path}/{action}", csrf, label, style)
                       for action, label, style in actions)
    return (f'<article class="person">{picture}<div><strong>{escape(row["display_name"])}</strong>'
            f'<p>{escape(row["username"])}</p><span class="pill {"on" if state == "pending" else ""}">'
            f'{escape(state.capitalize())}</span><div class="actions">{controls}</div></div></article>')


def session_card(row, csrf, timestamp):
    path = f'/admin/sessions/{quote(row["id"], safe="")}'
    open_session = row["expires_at"] > timestamp
    minutes = int((max(0, row["expires_at"] - timestamp) + 59) // 60)
    status = f'{minutes} min left' if open_session else "Closed"
    gps = f'GPS · {row["gps"]["radius_m"]:g} m' if row["gps"]["enabled"] else "GPS off"
    controls = ""
    if open_session:
        if row["gps"]["enabled"]:
            controls += button(f"{path}/gps/disable", csrf, "Disable GPS")
        controls += button(f"{path}/close", csrf, "Close session")
    a, b = row["codes"]
    total = row["total"]
    return f'''<article class="session">
    <div><strong>{escape(row["title"])}</strong>
    <div class="tags"><span class="pill {"on" if open_session else ""}">{status}</span><span>{gps}</span></div></div>
    <div class="codes" aria-label="Board codes"><span>{escape(a)}</span><span>{escape(b)}</span></div>
    <div><strong>{total}</strong> <span class="muted">check-ins</span></div>
    <div class="actions"><a class="button" href="{path}/results.csv">Export CSV</a>{controls}</div>
    </article>'''


STYLES = """
:root{color-scheme:light;--ink:#112d2e;--muted:#516367;--line:#dce5e3;--wash:#f3f7f5;--green:#096354}
*{box-sizing:border-box}html{scroll-padding-top:1rem}body{margin:0;background:var(--wash);color:var(--ink);
font:15px/1.48 system-ui,sans-serif}a{color:var(--green)}p{margin:.2rem 0;color:var(--muted)}
.shell{width:min(1120px,100%);margin:auto;padding:0 clamp(16px,4vw,40px)}header{background:white;border-bottom:1px solid var(--line)}
.top{min-height:66px;display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;padding-block:12px}
.brand{display:flex;align-items:center;gap:10px;font-size:18px;font-weight:750}.mark{display:grid;place-items:center;
background:var(--green);color:#fff;width:32px;height:32px;border-radius:10px}nav{display:flex;gap:20px;flex-wrap:wrap}
nav a{text-decoration:none;font-weight:620}main{padding-block:32px 56px!important}h1,h2{letter-spacing:-.035em;margin:0}
h1{font-size:clamp(32px,5vw,50px);line-height:1.05}h2{font-size:24px}.overview{display:flex;align-items:end;
justify-content:space-between;gap:20px;flex-wrap:wrap;margin-bottom:24px}.overview p{margin-top:8px}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:34px}.stat,.panel,.person,.session{
background:#fff;border:1px solid var(--line);border-radius:16px}.stat{padding:14px 17px}.stat span{display:block;color:var(--muted)}
.stat strong{font-size:27px;font-variant-numeric:tabular-nums}section{margin-top:34px}.section-head{display:flex;
justify-content:space-between;align-items:center;gap:12px;margin-bottom:12px}.panel{padding:18px;margin-bottom:12px}
.session,.person{padding:15px 16px;margin-top:9px}.session{display:grid;align-items:center;gap:13px;
grid-template-columns:minmax(8rem,1.15fr) auto auto minmax(8rem,1fr)}.session strong,.person strong{overflow-wrap:anywhere}
.codes,.tags,.actions{display:flex;gap:7px;align-items:center;flex-wrap:wrap}.codes span{padding:6px 9px;border-radius:8px;
background:#edf3f1;font:700 18px ui-monospace,monospace;letter-spacing:.04em}.pill{display:inline-block;font-size:12px;
font-weight:650;border-radius:999px;padding:3px 8px;background:#edf1f1;color:#43565a}.pill.on{background:#dff2e9;color:#075c49}
.tags{margin-top:5px;font-size:12px;color:var(--muted)}button,.button{font:600 13px system-ui;color:var(--ink);background:#fff;
border:1px solid var(--line);padding:8px 10px;border-radius:8px;cursor:pointer;text-decoration:none;display:inline-block}
button:hover,.button:hover{background:#eef5f2}.primary,.primary:hover{background:var(--green);color:#fff;border-color:var(--green)}
:focus-visible{outline:3px solid #259780;outline-offset:3px}.fields{display:grid;gap:12px;grid-template-columns:1fr 135px}
label{display:grid;gap:5px;font-weight:650;font-size:13px}input:not([type=hidden]){font:inherit;color:var(--ink);
background:#fbfdfc;border:1px solid var(--line);border-radius:8px;padding:9px 10px;width:100%}
details{margin:12px 0}summary{color:var(--green);font-weight:650;cursor:pointer}.override{max-width:290px;margin:8px 0}
.person{display:grid;grid-template-columns:90px 1fr;gap:14px}.person img,.avatar{width:90px;height:105px;border-radius:9px;
object-fit:cover;background:#edf3f1}.avatar{display:grid;place-items:center;color:var(--green)}.person .actions{margin-top:8px}
.people{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.muted{color:var(--muted)}.form-error{border-radius:8px;background:#fff0eb;color:#812d1c;padding:9px 12px;margin-bottom:12px}
@media(max-width:850px){.session{grid-template-columns:1fr auto}.session .actions{justify-content:flex-end}}
@media(max-width:560px){.people{grid-template-columns:1fr}.stat{padding:9px}.stat span{font-size:12px}
.session{grid-template-columns:1fr}.session .actions{justify-content:flex-start}.fields{grid-template-columns:1fr}.override{grid-template-columns:1fr 1fr}}
"""


def render_dashboard(*, room, enrollments, sessions, csrf, timestamp, form=None, form_error=None):
    form = form or {}
    title = escape(form.get("title", ""))
    duration = escape(form.get("ttl_seconds", "300"))
    a, b = (escape(form.get(key, "")) for key in ("code_a", "code_b"))
    error = f'<p class="form-error" role="alert">{escape(form_error)}</p>' if form_error else ""
    active = sum(row["expires_at"] > timestamp for row in sessions)
    pending = sum(row["status"] == "pending" for row in enrollments)
    total = sum(row["total"] for row in sessions)
    session_cards = "".join(session_card(row, csrf, timestamp) for row in sessions)
    person_cards = "".join(enrollment_card(row, csrf) for row in enrollments)
    room_text = escape(room) if room else "Calibrate the classroom in the phone app."
    return f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>ClassSweep · Instructor</title>
<style>{STYLES}</style>
<header><div class="shell top"><div class="brand"><span class="mark" aria-hidden="true">◎</span>ClassSweep</div>
<nav aria-label="Dashboard"><a href="#sessions">Sessions</a><a href="#enrollment">Enrollment</a><a href="/admin">Refresh</a></nav>
</div></header><main class="shell"><div class="overview"><div><h1>Attendance dashboard</h1><p>{room_text}</p></div>
<a class="button primary" href="#create">New session</a></div>
<div class="stats"><div class="stat"><span>Open sessions</span><strong>{active}</strong></div>
<div class="stat"><span>Awaiting review</span><strong>{pending}</strong></div>
<div class="stat"><span>Recorded check-ins</span><strong>{total}</strong></div></div>
<section id="sessions"><div class="section-head"><h2>Sessions &amp; results</h2></div>
<form id="create" class="panel" method="post" action="/admin/sessions/create">
<input type="hidden" name="csrf_token" value="{escape(csrf)}">
{error}<div class="fields"><label>Session title<input name="title" maxlength="150" required value="{title}" placeholder="e.g. Computer Vision"></label>
<label>Duration (seconds)<input name="ttl_seconds" type="number" min="30" max="1800" value="{duration}" required></label></div>
<details {"open" if a or b else ""}><summary>Override board codes for testing</summary>
<div class="fields override"><label>First code<input name="code_a" value="{a}" inputmode="numeric" pattern="[0-9]{{4}}" maxlength="4"></label>
<label>Second code<input name="code_b" value="{b}" inputmode="numeric" pattern="[0-9]{{4}}" maxlength="4"></label></div>
<p>Leave both blank for random codes. Close an open session before reusing its codes.</p></details>
<button class="primary">Create session</button></form>
{session_cards or '<p>No sessions yet.</p>'}</section>
<section id="enrollment"><div class="section-head"><h2>Enrollment review</h2></div>
<div class="people">{person_cards or '<p>No enrollments yet.</p>'}</div></section></main></html>'''
