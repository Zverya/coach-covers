# Coach Covers

A page your coaches open from a link, to hand over shifts and take each other's.
Static page on GitHub Pages; data in a free Supabase project.

The thing it guarantees: **two coaches cannot take the same shift.** The claim is a
single conditional `UPDATE` inside Postgres, so the second tap matches zero rows and
that coach is told who got there first. A WhatsApp thread cannot do this.

## Setup (once, ~10 minutes)

**1. Make the Supabase project**

Go to supabase.com, sign in with GitHub, create a new project. Any name; pick the
region closest to you (Frankfurt is the nearest to Israel). Free tier is plenty.

**2. Create the tables**

In the project: **SQL Editor → New query**. Paste all of `schema.sql`, press Run.
It finishes by printing two tokens — copy both:

- `SHARE TOKEN` — goes in the link you send coaches. Anyone holding it can see the
  board and claim shifts.
- `ADMIN TOKEN` — keep private. It is what lets shifts be pushed in.

**3. Get the project keys**

**Project Settings → API**: copy the **Project URL** and the **anon public** key.

The anon key is designed to be public and will sit in the page's source. That is safe
here: every table has row-level security on with no policies, so the key by itself
reads nothing. It can only call the functions in `schema.sql`, and each one checks a
token first.

**4. Save the admin config locally**

```
mkdir -p ~/.coach-covers
cat > ~/.coach-covers/config.env <<'EOF'
SUPABASE_URL=https://YOURPROJECT.supabase.co
SUPABASE_ANON_KEY=eyJ...
ADMIN_TOKEN=...
EOF
chmod 600 ~/.coach-covers/config.env
```

**5. Put the schedule in**

```
./push-shifts.sh ~/arbox-shifts/my-shifts.tsv
```

Re-run it whenever the schedule is re-pulled. It also re-checks every cover already
sent to the admin, and marks each one confirmed or still-wrong.

## The link

```
https://zverya.github.io/coach-covers/#t=SHARE_TOKEN
```

Send that to the coaches' group. No app, no account, no password — they open it, pick
their name once, and it remembers them on that phone.

## What coaches can do

- See every shift that needs a coach, soonest first, with how many hours are left.
- Take one. First tap wins; the loser is told who beat them.
- Hand over one of their own shifts.
- Give one back if they can't do it after all, as long as the admin hasn't been asked.

If someone takes a shift that clashes with one they already have at another box, the
claim still goes through but they're told about the clash — the point is that nobody
finds out on the morning.

## What this deliberately does not do

**It does not check who anyone is.** A coach picks their name from a list. Anyone with
the link could pick someone else's name. For fifteen colleagues sharing a schedule of
class times that is a reasonable trade for having no passwords; it would not be if the
link leaked widely. If that ever matters, the fix is a short PIN per coach.

**It does not change Arbox.** Nothing here touches your admin system. A human still has
to make the change there, and until they do the shift pays the wrong coach — which is
why `push-shifts.sh` re-checks and flags the ones that never got updated.
