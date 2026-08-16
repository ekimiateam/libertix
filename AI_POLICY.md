# AI Policy

How the Libertix project uses AI tools, and what we expect from contributors who
use them.

> **In one sentence:** use whatever tools you like. A human has to be
> responsible for the result and understand it.

---

## The principle

**Every contribution needs a human who is responsible for it and who
understands it.**

That is the whole policy. Everything below follows from it, spelled out with
examples so nobody has to guess.

We do not care whether you typed the code yourself, whether an agent wrote it,
or whether the two of you went back and forth for three hours. What matters is
that it works. If the code is good, the way it was produced is not a problem.
There just has to be a human answering for it.

---

## At a glance

| Situation | Our position |
|---|---|
| Writing code with an AI agent | Fine, no permission needed |
| Submitting a fully AI-generated patch | Fine, if you understand it and can defend it |
| Contributing without any AI | Equally fine, no pressure either way |
| An AI-written PR description | Fine |
| An agent answering review questions for you | Strongly discouraged |
| A third-party agent acting on the repo by itself | Not allowed |
| Solving a `good first issue` with an agent | Not allowed |
| Running AI review on code | Welcome, as an auditor, under human critical judgement; use it or not, either is fine |
| Naming the model you used | Strongly encouraged |

---

## How AI is used in this project

Parts of this codebase were written with the help of AI coding agents, Codex in
particular. We state this plainly rather than burying it, because you have a
right to know how the software you install on your machine was built.

Everything produced that way has been read and reviewed by a human maintainer
before being merged. AI review is used here too, but its output is itself
checked by a human. A model can flag things; it does not decide what gets
merged.

---

## Contributing with AI

### It is your choice

We do not require you to use AI tools, and we do not require you to avoid them.
Contribute the way you work best. Nobody here will think less of a patch because
an agent helped write it, and nobody will think less of a patch because it was
typed out by hand.

### We judge the code, not its origin

A contribution is evaluated on whether it works, whether it is maintainable,
whether it fits the project, and whether it is tested. A bad patch written by
hand is still a bad patch. A good patch written with an agent is still a good
patch.

Two rules further down are deliberate exceptions: [review
threads](#review-threads-need-you-not-your-agent) and [learning
issues](#learning-issues). Neither is about code quality. Both are about people.

### Telling us what you used

We strongly encourage you to declare AI use, and not as a formality.
Different models behave differently. If a class of bug turns out to
be characteristic of a particular model or version, being able to find every
affected commit with one `git log --grep` is worth a great deal.

If you want to mention it, use the commit trailers the wider open source
ecosystem has settled on:

```
Assisted-by: <model name and version>
Signed-off-by: Your Name <you@example.org>
```

- Use `Generated-by:` instead when the tool produced the change with little
  intervention from you.
- Name the specific model and version. `Assisted-by: GPT-5-Codex` tells us
  something; `Assisted-by: AI` does not.
- **Do not use `Co-authored-by:` for an AI tool.** That trailer records a human
  co-author, with the legal standing that implies. The tool is not an author of
  your contribution. You are, because you directed it, reviewed it, and are
  answerable for it. `Assisted-by:` and `Generated-by:` record which tool was
  involved without making that claim.

### Provenance and licensing

Libertix is licensed under the **GNU General Public License v3.0**, and every
contribution must be compatible with it. Three things follow, and they apply
identically whether or not you used a tool:

1. **You are responsible for having the right to submit what you submit.**
2. **Do not knowingly submit code that reproduces another project's work.** This
   matters with generative tools specifically: they can reproduce training
   material without carrying over the license, the attribution, or the notices
   that came with it.
3. **If your change incorporates code from elsewhere, say where it came from**
   and check that its license is compatible with GPL-3.0.

Sign your commits off with `git commit -s`. The [Developer Certificate of
Origin](https://developercertificate.org/) is a short statement that you have
the right to contribute the work. One flag, and it covers all of the above.

If your assistant offers a public-code or duplication filter, turn it on.

---

## Human presence

### Review threads need you, not your agent

The description of your pull request can be AI-written. That is fine, and it is
often clearer than what any of us would type at 2am.

The discussion is different. When a reviewer asks a question, we would much
rather hear from you than from your agent. If we wanted a model's answer, we
would ask our own, and that takes ten seconds and costs you nothing. What review
is actually for is finding out whether a human understands this change well enough
to maintain it.

This is advice, not a rule with a penalty attached. But here is what happens in
practice: if a thread turns into an agent producing answers that miss the point,
with no human stepping in, we reserve the right to rework the change
substantially ourselves or to leave it unmerged. Not as punishment, but simply
because nobody has shown that the change is understood.

### Autonomous agents

| Allowed | Not allowed |
|---|---|
| CI, dependency bots, linters, security scanners | A third-party agent that watches this repo and acts on it |
| AI review bots the maintainers choose to run | An agent fetching issues and opening PRs on its own |
| An agent **you** started, deliberately, on your own branch | An agent replying to threads with no human behind it |

The problem is not automation. Maintainer-configured automation is welcome; we
set it up and we answer for what it does.

The problem is that an agent starting *by itself* acts without anyone having seen
it coming. There is no moment where a human looked at what was about to happen
and decided it was worth doing. The contributor finds out at the same time we do,
if they find out at all.

**A human has to know about the action, have had the time to look at it, and have
wanted it.** Nobody should be caught off guard by what lands on this repository,
neither you nor us.

---

## Learning issues

Some issues here exist to produce a result. Others exist so that somebody
learns something. The second kind has rules.

| Label | For | Please do not |
|---|---|---|
| `good first issue` | People learning to program | Solve it with an AI agent |
| `good first issue (AI)` | People learning to work with AI agents | Solve it by hand, or let an agent fetch and resolve it automatically |

`good first issue` exists so that people learning to program have somewhere to
start. These issues are not there to be cleared. **What matters is not the
result, it is the path someone takes to get there.** Solving one with an agent
takes that away from a beginner and gains the project nothing.

Issues labelled for AI use exist for the symmetrical reason: learning to use
these tools well is a real skill, and it deserves somewhere to be practised. Same
logic, same respect: start the agent yourself, deliberately, and stay with it.
Automating the whole thing defeats the point just as much as doing it by hand
does.

We cannot enforce any of this technically. We are asking.

---

## AI code review

We find AI review genuinely useful for surfacing weaknesses, edge cases, and
problems a tired human reviewer walks straight past. It is a cheap outside
opinion, and outside opinions are valuable.

It is advisory, on your pull requests and on ours. An AI reviewer's approval is
not a merge criterion, and its objection is not a veto.

---

## If you disagree with this policy

Some projects have taken a much stricter line, refusing AI-derived contributions
outright, usually on the grounds that AI-generated code may have no clear
copyright holder and therefore weakens copyleft enforcement. That is a serious
argument and we do not dismiss it. We have chosen a different approach, based on
human accountability and review rather than on the provenance of the keystrokes.
There is no consensus in open source on this question today, and we may well turn
out to be wrong.

If the use of AI assistance here bothers you, the most useful thing you can do is
**read the code and tell us what is actually wrong with it**. Specific, factual
findings are welcome and will be acted on. That is how the project gets better,
and it is worth more to us than agreement.

And if you would rather build something different from it, the GPL guarantees
your right to fork. No hard feelings.

What we would rather avoid is the argument conducted purely in the abstract. The
point of this project is a free installer that works and that helps people move
to Linux. Ego is not welcome here, including ours.

---

## This policy will change

The legal and practical landscape around AI-assisted contributions is moving
fast, and this document will be revised as it does.

If you think something here is wrong or unclear, open an issue.