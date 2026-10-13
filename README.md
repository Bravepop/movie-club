# Movie Club

A free site where anyone can start a private movie club: take turns picking films in a set order, then rate, review and vote on each other's takes.

- **Site:** `index.html` + `config.js`, a static page served by GitHub Pages.
- **Data, sign-in and images:** one Supabase project shared by every club. The access rules in `supabase/schema.sql` keep each club visible only to its members.
- **Sign-in:** Google, or a username and password. No emails are ever sent: username accounts get a recovery code at sign-up, and with it people set a new password themselves.

## How clubs work

- Anyone signed in can **start a club** (up to 5 each). They become its admin.
- The admin sends the club's **invite link**. People sign in with Google, open the link and join, either as a new name or by claiming a name the admin added (which keeps that name's past ratings).
- Admins manage everything from **Club settings** (gear icon): members, pick order, guests, other admins, the invite link, screening dates and deleting the club.
- Members can **leave** a club or **delete their account**. Their name and ratings stay in each club's history, unlinked.

Limits that keep the free tiers comfortable: 40 members per club, 20 clubs per person, 1,500 screenings per club, 60 party images per club (3 MB each; party mode is only switched on for JBOIZ), 300 watchlist films per person.

## One-time setup

### 1. Supabase project
1. Sign in at [supabase.com](https://supabase.com) with the service's Google account and create a project named `movie-club` in the region nearest you.
2. **SQL Editor → New query**: paste all of `supabase/schema.sql` and click **Run**.

### 2. Google sign-in
1. In [Google Cloud Console](https://console.cloud.google.com/), signed in as the service's Google account, create a project named `Movie Club`.
2. **APIs & Services → OAuth consent screen**: choose **External**, app name `Movie Club`, add the support email, and publish the app (it only asks for name and email, so Google doesn't need to review it).
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**: type **Web application**. Under **Authorized redirect URIs** add `https://<your-project-ref>.supabase.co/auth/v1/callback` (Supabase shows the exact address on its Google provider page).
4. In Supabase, **Authentication → Sign In / Providers → Google**: turn it on and paste the client ID and secret.
5. **Authentication → URL Configuration**: set **Site URL** to the site's address (for example `https://movieclub-app.github.io/movie-club/`) and add the same address, plus `http://127.0.0.1:5191/**` for local testing, under **Redirect URLs**.

### 3. Username accounts
**Authentication → Sign In / Providers**: turn **Email** on and **Confirm email** off. Usernames are stored as `<username>@users.bravepop.app`; nothing is sent there.

### 4. Connect the site
**Project Settings → API Keys**: copy the project URL and the publishable key into `config.js`. Both are meant to be public; the access rules protect the data.

Optional: a free [TMDB](https://www.themoviedb.org/settings/api) API key in `config.js` turns on film search and posters.

### 5. Publish
Push this folder to a GitHub repo and turn on **Settings → Pages** (deploy from the `main` branch, root folder).

The privacy page lists `movieclub@bravepop.app` as the contact address (forwarded by Cloudflare Email Routing).

## Running it

**The site says the database is unreachable.** Free Supabase projects pause after a week with no visits. Open the Supabase dashboard and click **Restore project**.

**Missed screenings** are marked automatically each morning (07:00 UTC) for rotation members who haven't rated a watched film within a week. Rating it later clears the mark.
