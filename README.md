[![Actions Status](https://github.com/m-doughty/MCP-Server-Tool-Ask/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/MCP-Server-Tool-Ask/actions)

MCP::Server::Tool::Ask
======================

An ask-the-user tool for [MCP::Server](https://github.com/m-doughty/MCP-Server), built on genuine server-side elicitation.

Every other tool a model can call is something it does *to* the world. This is the one that goes the other way: the model has run out of information, and the person who asked for the work is the only one who has it. The pack registers a single tool — `ask` — which renders a form, blocks until the user fills it in, and hands the answers back to the model as JSON.

Underneath it is the 2026-07-28 multi round-trip request pattern: the tool call is answered with `resultType: "input_required"`, the client shows the user a form, and the call resumes exactly where it stopped. Nothing is polled, nothing is faked client-side, and the handler is never re-run.

Synopsis
--------

Plug it into a server you are building by hand:

```raku
use MCP::Server;
use MCP::Server::Tool::Ask;

my $server = MCP::Server.new(:name<assistant>, :version<1.0>);

$server.plug: MCP::Server::Tool::Ask.new;   # registers user_ask

$server.run;   # stdin/stdout
```

Or name it in a one-shot server, with no `use` statement at all — the toolkit is loaded at runtime:

```raku
use MCP::Server;

MCP::Server.new(
    :name<assistant>,
    :tools['Ask' => { timeout => 120 }],
).run;
```

Or hand `raku-mcp` a config file:

```json
{
  "name": "assistant",
  "version": "1.0",
  "instructions": "Ask before guessing.",
  "tools": {
    "Ask": { "timeout": 120 },
    "FileSystem": { "root": "/srv/notes" }
  }
}
```

```shell
raku-mcp --config=assistant.json

# Or without a file:
raku-mcp --tool='Ask={"timeout":120}'
```

Configuration
-------------

<table class="pod-table">
<thead><tr>
<th>Key</th> <th>Type</th> <th>Default</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>timeout</td> <td>Real</td> <td>unset</td> <td>Seconds to wait for one answer before treating it as a cancellation. Unset means the wait is bounded only by the server&#39;s own C&lt;elicitation-ttl&gt; (five minutes by default). Zero or negative dies.</td> </tr>
</tbody>
</table>

`prefix` is reserved by the framework rather than the pack: pass it to `.plug` as `:prefix<...> `, or put it beside the toolkit's settings in a `:tools` entry or config file. Without one, the pack's default prefix `user` applies, so the tool is `user_ask`; an explicit empty prefix registers it bare.

What the client has to support
------------------------------

The tool needs somebody to ask. That means one of:

  * A **2026-07-28 client that declared the elicitation capability** (`elicitation: { form: {} } ` in its `_meta` `clientCapabilities`). This is the real path: the question goes to the client, the client asks the human.

  * A server configured with **`:&on-elicit`**, which answers questions locally. That covers legacy-era clients, the LLM tool bridge (`execute-tool-calls`), and anything driving handlers directly.

With neither, calling the tool comes back as an error result naming which of the two is missing — it does not hang, and it does not invent an answer. See the "Elicitation" section of `MCP::Server`'s documentation for the whole picture.

The tool
--------

### ask(message, questions?)

<table class="pod-table">
<thead><tr>
<th>Parameter</th> <th>Type</th> <th>Required</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>message</td> <td>string</td> <td>yes</td> <td>The framing: why the model is asking. Shown above the form.</td> </tr> <tr> <td>questions</td> <td>array</td> <td>no</td> <td>The fields to ask for. Omit it (or send an empty list) to ask one free-form question.</td> </tr>
</tbody>
</table>

The `Required` column is the published JSON Schema's `required` array, so a model knows before it calls that there is no asking a person nothing. Neither parameter publishes a JSON Schema `default`: omitting `questions` is not a value being substituted but a different question altogether — one free-form field instead of a form — and there is no default value that says that.

Each entry of `questions` is an object:

<table class="pod-table">
<thead><tr>
<th>Key</th> <th>Type</th> <th>Default</th> <th>Meaning</th>
</tr></thead>
<tbody>
<tr> <td>name</td> <td>string</td> <td>required</td> <td>The key the answer comes back under. Must be unique within the call.</td> </tr> <tr> <td>prompt</td> <td>string</td> <td>—</td> <td>What to show the user for this field. Becomes the property&#39;s C&lt;description&gt;.</td> </tr> <tr> <td>type</td> <td>string</td> <td>&quot;string&quot;</td> <td>One of C&lt;string&gt;, C&lt;number&gt;, C&lt;boolean&gt;.</td> </tr> <tr> <td>options</td> <td>array</td> <td>—</td> <td>Strings to choose between; becomes an C&lt;enum&gt;. Only valid on a string question.</td> </tr> <tr> <td>required</td> <td>boolean</td> <td>true</td> <td>Whether the user must fill this field in.</td> </tr>
</tbody>
</table>

A call with three fields:

```json
{
  "message": "I need a few details before I can file the ticket.",
  "questions": [
    { "name": "component", "prompt": "Which component?", "options": ["api", "ui", "docs"] },
    { "name": "severity",  "prompt": "How bad is it?",   "type": "number" },
    { "name": "notes",     "prompt": "Anything else?",   "required": false }
  ]
}
```

...becomes this `requestedSchema` on the wire:

```json
{
  "type": "object",
  "properties": {
    "component": { "type": "string", "description": "Which component?",
                   "enum": ["api", "ui", "docs"] },
    "severity":  { "type": "number", "description": "How bad is it?" },
    "notes":     { "type": "string", "description": "Anything else?" }
  },
  "required": ["component", "severity"]
}
```

...and comes back to the model as text:

    {"component":"api","notes":"","severity":2}

Keys are sorted and the JSON is not pretty-printed: this text goes into a model's context, where stability is worth more than insertion order and newlines are worth nothing at all.

With no `questions`, the form has a single required string field called `answer`, which is what a model reaching for "just ask them" wants nine times out of ten:

    {"answer":"go ahead, but stage it first"}

Refusal is an answer
--------------------

A user who declines or cancels gets a plain, non-error result:

  * `The user declined to answer.`

  * `The user cancelled the request.`

Neither carries `isError`, and that is deliberate. `isError` tells a model that something went wrong and that trying again might work — so an error result here would send it straight back to ask the same person the same question. A person saying no is the system working. The tool's description tells the model as much: carry on without the answer, or stop and explain why it cannot.

The same goes for a client that answers with something that is not an `ElicitResult` at all: that is read as a decline rather than as a fault.

Errors
------

These *are* error results, because each is a call the model can fix and retry:

  * A missing, non-string or empty `message`.

  * `questions` that is not a list, or an entry that is not an object.

  * A question with no `name`, or two questions sharing one — answers come back keyed by name, so a duplicate would silently lose one.

  * An unsupported `type`, `options` on a non-string question, an empty `options` list, or a `required` flag that is not a boolean.

  * An unknown key in a question object, listing the valid ones.

And, as above, calling the tool at all when there is nobody to ask.

Security and etiquette
----------------------

  * **This tool interrupts a human.** It is not free the way reading a file is. A model that asks about everything is worse than one that asks about nothing, and the tool description is written to push it toward asking only when it genuinely cannot proceed. If you find a model over-using it, say so in the server's `instructions`.

  * **An answer is user input, not truth.** It arrives as JSON straight from whatever the client's form produced. Validate it before acting on it, exactly as you would any other input, and do not treat "the user typed it" as authorisation for something the user did not understand they were authorising.

  * **A parked call holds server state.** Each unanswered question occupies a place in the server's elicitation table (64 by default) until it is answered or the TTL expires. Set `timeout` if you would rather give up sooner than the server-wide TTL.

  * **Asking is inherently consented.** A permission layer in front of the server — Claude Code's rules, [MCP::Client::Policy](https://github.com/m-doughty/MCP-Client) — should normally allow `user_ask` outright: prompting the user for permission to prompt the user helps nobody.

  * **This pack declares no MCP annotations, deliberately.** `ask` writes nothing, so `readOnlyHint => True ` would be defensible — and a host reads that (with `idempotentHint`) as permission to run two of them at once, which is the last thing a tool that parks the call on a human wants: two questions racing to the front of one person's attention is a worse conversation than two questions in a row. It is not idempotent either. Asking the same question twice asks a person twice. "Safe to describe as read-only" and "safe to run beside its neighbours" are different questions about the same tool, and an annotation answers the second.

Testing
-------

```shell
prove6 -Ilib t/                          # with MCP::Server installed
prove6 -Ilib -I../MCP-Server/lib t/      # against a sibling checkout
```

`t/02-tool.rakutest` drives every question shape through a server with a scripted `:on-elicit` behind it; `t/03-mrtr.rakutest` does the same thing the long way round, over a real multi round-trip with no local callback anywhere.

Examples
--------

  * `examples/ask-server.raku` — a Streamable HTTP server with a terminal-prompt `:on-elicit` fallback, so both paths can be watched side by side: a client that declares the capability gets the form over the wire, and one that does not sends the question to the terminal the server was started from. (HTTP rather than stdio because a stdio server has already spent stdin and stdout on the protocol.)

Author
------

Matt Doughty

License
-------

Artistic-2.0

