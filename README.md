# Coach Covers

One page, three roles. Coaches see their own week and hand shifts over; other coaches
take them; an approver signs the swap off before it becomes real in Arbox.

Static page on GitHub Pages, data in a free Supabase project.

The thing it guarantees: **two coaches cannot take the same shift.** A claim is a single
conditional `UPDATE` inside Postgres, so the second tap matches zero rows and that coach
is told who got there first. A WhatsApp thread cannot do this.

## Who sees what

| | Coach link | Approver link |
|---|---|---|
| Own week, as a calendar | yes | yes |
| Ask for cover on own shift | yes | yes |
| Take someone else's shift | yes | yes |
| Give back a shift (before approval) | yes | yes |
| See every request in one queue | no | yes |
| Approve or send back a swap | no | yes |
| Copy the change list for Arbox | no | yes |

Same page, same link format — the token decides. Coaches never see the approval queue.

## The flow

1. A coach taps a class in their week and asks for cover. It goes on the board.
2. Another coach takes it. First tap wins; the loser is told who beat them.
3. It lands in the approver's queue as **Waiting for you**.
4. The approver approves it, or sends it back to the board with a note.
5. Approved swaps appear under **Change these in Arbox**, with a copyable change list.
6. Next time the schedule is pushed in, each approved swap is checked against what Arbox
   actually says, and anything that never got changed is flagged — because until it is,
   the original coach gets paid for a class they didn't teach.

## Setup (once, ~10 minutes)

**1. Make the Supabase project.** supabase.com → sign in with GitHub → new project.
Frankfurt is the closest region to Israel. Free tier is plenty.

**2. Create the tables.** SQL Editor → New query → paste all of `schema.sql` → Run.
It finishes by printing three tokens:

- **COACH LINK token** — goes in the link you send the coaches' group.
- **APPROVER LINK token** — goes in the link you send whoever approves. Only that.
- **ADMIN token** — never goes in a link. It is what lets schedules be pushed in.

**3. Get the project keys.** Project Settings → API → copy the **Project URL** and the
**anon public** key.

The anon key is designed to be public and sits in the page source. That is safe here:
every table has row-level security on with no policies, so the key alone reads nothing.
It can only call the functions in `schema.sql`, and each checks a token first.

**4. Save the admin config locally.**

```
mkdir -p ~/.coach-covers
cat > ~/.coach-covers/config.env <<'EOF'
SUPABASE_URL=https://YOURPROJECT.supabase.co
SUPABASE_ANON_KEY=eyJ...
ADMIN_TOKEN=...
EOF
chmod 600 ~/.coach-covers/config.env
```

**5. Put the schedule in.**

```
./push-shifts.sh ~/arbox-shifts/my-shifts.tsv
```

Re-run whenever the schedule is re-pulled. It also re-checks every approved swap.

## The two links

```
coaches:   https://zverya.github.io/coach-covers/#t=COACH_TOKEN
approver:  https://zverya.github.io/coach-covers/#t=APPROVER_TOKEN
```

No app, no account, no password. Coaches pick their name once and the phone remembers.

## What this deliberately does not do

**It does not check who anyone is.** A coach picks their name from a list, so anyone
holding a link could pick someone else's name — including, with the approver link, the
right to approve. For a handful of colleagues sharing class times that is a fair trade
for having no passwords; treat the approver link as the more sensitive of the two. If it
stops feeling fair, the fix is a short PIN per coach.

**It does not change Arbox.** Nothing here touches your admin system. A human still makes
the change there, which is exactly why step 6 above exists.
