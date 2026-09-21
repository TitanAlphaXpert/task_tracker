# Job Card — Daily Task Tracker

## What changed

This version replaces the original `window.storage` data layer with a shared Supabase Postgres backend.

Implemented:
- 3 separate dealerships.
- Public URL is okay; employees must select their dealership, name and enter their personal PIN.
- Employees can see only their own tasks.
- Manager PIN protects the manager area.
- Manager can see all three dealerships.
- Employee "Done" requires confirmation.
- Exact completion timestamp is stored.
- If completed after the due date, status becomes **Completed Late**.
- Manager can edit task title, due date and assignee after assignment.
- Manager can delete tasks.
- Manager can resolve help requests and reopen completed tasks.
- Help requests are stored against the task.
- Employee PINs and manager PIN are stored as SHA-256 hashes in the database, not as plaintext in the website.
- India time zone is used for the due-date/late calculation.
- Audit log records task creation, completion, help request, update and deletion.
- No WhatsApp integration.

## 1. Create the free database

1. Create a Supabase project.
2. Open **SQL Editor**.
3. Paste the complete `supabase.sql` from this folder.
4. Run it.
5. The SQL seeds:
   - ATC Mobility Aurangabad
   - Unicon Latur
   - Unicon Ahmednagar
6. Change the manager PIN seed before first use. The example is `CHANGE-ME-1234`.

To generate a new manager PIN hash:
```sql
select encode(digest('YOUR_NEW_MANAGER_PIN','sha256'),'hex');
```

Then:
```sql
update public.app_config
set value = encode(digest('YOUR_NEW_MANAGER_PIN','sha256'),'hex')
where key = 'manager_pin_hash';
```

## 2. Configure the website

Open `index.html` and replace:
```js
const SUPABASE_URL = "PASTE_YOUR_SUPABASE_URL_HERE";
const SUPABASE_ANON_KEY = "PASTE_YOUR_SUPABASE_PUBLISHABLE_KEY_HERE";
```

with the project's URL and publishable/anon key from Supabase.

Do NOT put a Supabase service-role/secret key into this file.

## 3. Add your employees

Open the manager area from the gear icon:
- Enter manager PIN.
- Team tab.
- Select dealership.
- Add employee name.
- Give the employee a 4–6 digit PIN.

Employees then use:
**URL → dealership → name → personal PIN → own tasks**

## 4. Free hosting

The website is static and can be hosted on a free static-hosting service such as GitHub Pages or Cloudflare Pages.

Upload `index.html` as the site's main file.

The database remains in Supabase; all three dealerships use the same URL and database.

## Important security scope

This is intentionally the requested Level-1 internal tool. The PIN is checked server-side by database functions and is not embedded as a hardcoded manager PIN in the browser.

For a stronger production authentication system later, move employees to real authenticated accounts and use Supabase Auth + RLS/JWT-based policies.

## Current manager capabilities

- Dashboard across all dealerships
- Assign task
- Board across all dealerships
- Edit task title/due date/assignee
- Delete task
- Add/remove employees
- View completed-late counts
- View help requests

## Current limitation

The manager PIN remains in the browser session so manager RPC calls can be authenticated without a full login system. For Level 1 this is acceptable, but anyone who obtains the manager PIN can use manager functions.

