# Beep Beep Landing Page

Static Firebase Hosting site with a small Firebase Function that forwards waitlist submissions to Bird.

## Local Preview

```sh
python3 -m http.server 8080 -d landing/public
```

The static preview loads at `http://localhost:8080`. The waitlist endpoint requires Firebase emulation or a deployed function.

## Waitlist Setup

The landing page keeps the public conversion as an email waitlist. On submit, the function:

- creates or updates a Bird contact by email;
- adds the contact to the Bird pending waitlist list;
- sends the configured operator email a notification so your inbox mirrors new signups.

Approval stays manual: review the pending contacts in Bird, then send selected people the WhatsApp beta invite through Bird when you want to open the next batch.

Create a Bird contact list and an email channel, then collect:

| Value | Where it goes |
| --- | --- |
| Workspace ID | `BIRD_WORKSPACE_ID` |
| Waitlist contact list ID | `BIRD_WAITLIST_LIST_ID` |
| Email channel ID | `BIRD_EMAIL_CHANNEL_ID` |
| Access key | Firebase secret `BIRD_ACCESS_KEY` |
| Your notification address | `WAITLIST_NOTIFY_EMAIL` |

Keep the WhatsApp invite link out of the public site. Put it in the Bird email/template/campaign you send only to approved testers.

## Finding Bird Values

These are not new fields to create in code. They are IDs for things in Bird.

| Env var | How to find it |
| --- | --- |
| `BIRD_WORKSPACE_ID` | In Bird, click the organization logo/name, open Organization settings, go to Workspaces, edit the workspace, then copy the Workspace ID. |
| `BIRD_WAITLIST_LIST_ID` | In Bird Contacts/Audience, create a list named `Beep Beep Waitlist Pending`, open it, then copy the UUID from the URL or list details. |
| `BIRD_EMAIL_CHANNEL_ID` | In Bird Channels/Email, open the email channel/sender you want to send notifications from, then copy the channel UUID from the URL or channel details. |
| `WAITLIST_NOTIFY_EMAIL` | The inbox that should receive new-signup notifications, for example your own email. |

If the Bird UI hides an ID, open the object and copy the browser URL. The UUID in the URL is usually the value needed here.

## Firebase Setup

From `landing/`:

```sh
npm --prefix functions install
firebase use beepbeep-b31ee
firebase functions:secrets:set BIRD_ACCESS_KEY
cp functions/.env.example functions/.env.beepbeep-b31ee
```

Fill in `functions/.env.beepbeep-b31ee`, then deploy.

Deploy:

```sh
firebase deploy --project beepbeep-b31ee
```

After deploy, add the apex/root domain through Firebase Hosting's custom domain flow. Firebase will provide the DNS records for the root.
