# Writing references

## Find relevant sources

When retrieval is useful, start with user-provided examples or designated
locations, including local repositories and writing archives. Search and read
those local sources directly within the requested scope. For connected sources,
discover the search and read capabilities of apps the user has enabled and
connected. Call the relevant source connectors directly, using their live tool
schemas and supported query syntax. Do not assume an app is connected merely
because its integration is listed.

Choose sources for this particular request: the desired medium, audience,
communication purpose, and any links or locations the user supplied. Search
the most promising sources first, not every available app. For example:

- Slack or Microsoft Teams for channel posts, manager updates, and other work
  chat, especially in the relevant channel or conversation.
- Gmail or Outlook Email for customer emails, colleague correspondence, and
  email-based updates, prioritizing messages sent by the user.
- Google Drive, SharePoint, OneDrive, Confluence or Notion for documents,
  proposals, reports, PRDs, board memos, presentations, and notes in the
  relevant files or spaces.

These are examples, not required integrations or fixed mappings. Use another
enabled app when the user's context makes it a better source; a manager update
might be in email rather than chat, and a proposal might be linked from a chat
thread. Follow relevant source links only through available, authorized access.

Use supported sender or author filters for the connected user's account where
available, then narrow by audience, channel, recipient, document type, or
purpose. Add topic and date constraints when they help; do not discard a strong
style match merely because it concerns another topic. Adapt searches to each
connector rather than copying one app's query syntax to another. Do not assume
that owning or editing a shared document means the user wrote all of it.

For an end-of-week Slack update to a manager, for example, search the user's
past messages in the appropriate conversation for progress, blockers, and next
steps. For a PRD, start with the connected document sources. If a result needs
more context to establish relevance or obtain its original link, use that
source's read or metadata action only as needed.

Select titles and source links from the results. Reuse suitable results already
retrieved for this writing request. Search local writing folders when designated
by the user; do not explore unrelated local archives. Do not maintain a cache or
index, or persist retrieved samples to disk or another library. An approved
style profile may retain general tendencies without copying private content.

If results are weak, refine the query or try the next relevant connected source.
Stop when a strong set is available or the likely sources have been checked;
do not broaden into unrelated apps merely to fill three slots. If a source is
unavailable, restricted, or fails, try another relevant enabled source, use
user-provided examples, or continue without a style match. Do not bypass access
restrictions or claim an access failure proves that no prior writing exists.

## Choose up to three references

Prefer three strong, distinct references when available. Rank by medium and
audience fit, then communication purpose, relevant context, and useful stylistic
variety.

Compare what each piece is doing: reporting progress, explaining a decision,
requesting approval, resolving a problem, or offering a next step. Return fewer
when fewer qualify; do not pad with unrelated material or duplicate references
from the same source to reach three.

Select sources containing the user's original prose, not assistant replies,
quoted or forwarded messages, signatures, or unrelated collaborators' text.
Use the available result context to rank references. Before using an example
as style evidence, read enough of its original prose to observe structure,
sentence length, tone, detail, caveats, and sign-off. Search snippets may suffice
for a short message; read the relevant passage of longer material when needed.
Titles and links identify sources but do not establish writing style. If the
text cannot be read, use the approved profile and do not claim to have learned
from that example.

Do not fetch full content merely to expand a handoff. Keep excerpts, summaries,
and style analyses out of title-and-link handoffs. Omit secrets and unrelated
sensitive details.

When the user explicitly selects uploaded or linked writing as a favorite
style, use that material instead of searching their own writing. Keep its actual
source distinct from the user's prose, and do not expand beyond the designated
material unless asked. The same title-and-link-only handoff and three-reference
limit apply.

## Internal handoff

Provide up to **three writing references**, best match first, in plain text or
Markdown. Use this form for each reference, not JSON:

```text
### <Title or short description>
<Original source link>
```

Use the original title and link when supplied. A descriptive title is fine if
the source has none. For a user-designated local source, use its absolute file
path with a line number when available. Otherwise, skip a result without a
usable source link; do not invent one. Include only the title and source link
(or local file reference), with no writing text, excerpts, summaries, or
additional fields. The three-reference
limit counts distinct writing sources, not provider sections or a combined
tool-response string.

When composing in the same task, keep the selected references internal without
echoing the tool response. If retrieval is delegated, pass only the selected
title-and-link blocks to the writing agent through the internal task result,
never the raw tool response or sample text. The writing agent should read the
selected sources through its own authorized access before using their style.
If it cannot access them, use the approved profile without claiming those
sources informed the draft. Delegation is optional; a single agent can select,
read, and apply the references within the same task.

Search or read results may include body text. This skill controls the handoff,
not the connectors' raw responses: it cannot remove text already placed in the
calling model's context. Do not claim that this variant guarantees a text-free
model context.

Keep the reference handoff out of normal progress messages and the final answer.
Show the requested writing. Expose examples only when the user asks for them.
If none qualifies, record "No suitable writing references found in the returned
results" internally and continue. Mention retrieval limitations only when they
materially affect the requested result.

## Style analysis and maintenance

For an explicit style-analysis or skill-maintenance request, read enough of the
user-designated material to support the analysis. The three-reference limit and
title-and-link-only handoff rules above apply to ordinary drafting, not this
analysis workflow. Share evidence-backed patterns and proposed changes when
requested. Distinguish the user's original prose from collaborators' messages,
quotes, forwarded material, templates, and potentially assisted writing. Weight
repeated patterns across contexts more heavily than isolated examples. Do not
turn a situational choice into a universal rule. Honor any request to review
proposed changes before editing the skill. Keep private substance out of reusable
style guidance. Do not automatically persist inferred preferences or update the
skill after routine drafting; make lasting changes when the user requests them.
