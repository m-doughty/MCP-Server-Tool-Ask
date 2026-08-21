use JSON::Fast;

use MCP::Server::Toolkit;

#| A tool that lets the model ask the human a question.
#|
#| Everything else a model can do through MCP is something it does I<to> the
#| world: read a file, call an API, write a row.  This is the one that goes the
#| other way — the model has run out of information and the person who asked for
#| the work is the only one who has it.  Underneath, it is
#| C<$*MCP-REQUEST-CONTEXT.elicit>: the tool call is answered with
#| C<resultType: "input_required">, the client renders a form, and the call
#| resumes with the answers in hand.
#|
#|   my $server = MCP::Server.new(:name<assistant>);
#|   $server.plug(MCP::Server::Tool::Ask.new);   # registers user_ask
#|
#| Or from configuration, which is how a deployment usually does it:
#|
#|   MCP::Server.new(:name<assistant>, :tools['Ask' => { timeout => 120 }]);
#|
#| =head2 What the model sends
#|
#| C<message> is the framing — why it is asking — and C<questions> is an
#| optional list of fields:
#|
#|   {
#|     "message": "I need a few details before I can file the ticket.",
#|     "questions": [
#|       { "name": "component", "prompt": "Which component?",
#|         "options": ["api", "ui", "docs"] },
#|       { "name": "severity", "prompt": "How bad is it?", "type": "number" },
#|       { "name": "notes", "prompt": "Anything else?", "required": false }
#|     ]
#|   }
#|
#| With no C<questions> at all it asks for a single free-form C<answer>, which
#| is what a model reaching for "just ask them" produces most of the time.
#|
#| =head2 What comes back
#|
#| An accepted form comes back as JSON with sorted keys — stable enough for a
#| model to read and for a test to compare:
#|
#|   {"component":"api","notes":"","severity":2}
#|
#| A refusal comes back as plain text and B<never> as an error result:
#|
#| =item C<The user declined to answer.>
#| =item C<The user cancelled the request.>
#|
#| That is deliberate.  C<isError> tells a model that something went wrong and
#| that trying again might work; a person who declined to answer is neither.
#| The model should carry on without the answer, or stop and say why it cannot.
#|
#| =head2 Requirements
#|
#| The client has to be able to be asked: a 2026-07-28 client that declared the
#| C<elicitation> capability, or a server configured with C<:on-elicit> as a
#| local fallback.  Without one of those, calling the tool comes back as an
#| error result explaining which — see C<MCP::Server>'s "Elicitation" section.
unit class MCP::Server::Tool::Ask does MCP::Server::Toolkit;

#| Seconds to wait for an answer before giving up on one question and treating
#| it as a cancellation.  Undefined by default, which means the wait is bounded
#| only by the server's own C<elicitation-ttl>.
has Real $.timeout;

# What a question may ask for.  The elicitation form is flat and primitive by
# design -- the client has to render it for a human -- so this is the whole
# vocabulary, and anything outside it is a mistake in the call rather than
# something to be silently dropped.
my constant QUESTION-TYPES = Set.new(<string number boolean>);
my constant QUESTION-KEYS = Set.new(<name prompt type options required>);

submethod TWEAK() {
	die "Ask timeout must be greater than zero seconds, got $!timeout"
		if $!timeout.defined && $!timeout <= 0;
}

method default-prefix(--> Str) { 'user' }

method register($registrar) {
	# DELIBERATELY UNANNOTATED, and it is the one registration in the packs
	# where that is a decision rather than an omission.  "ask" writes nothing,
	# so calling it read-only would be defensible -- and it would be read by a
	# host as permission to run two of them side by side, which is the last
	# thing this tool wants: it parks the call on a human, and two questions
	# racing to the front of one person's attention is a worse conversation
	# than two questions in a row.  It is not idempotent either.  Asking the
	# same question twice asks a person twice.
	#
	# "Safe to repair as read-only" and "safe to run concurrently" are
	# different predicates about the same tool, and only the second is what an
	# annotation grants.  See MCP::Server::Batch.
	$registrar.tool: 'ask',
		description => 'Ask the user a question and wait for their answer. Use '
			~ 'this when you are missing something only the user can tell you: a '
			~ 'choice between options, a value you cannot infer, or permission to '
			~ 'go ahead. Give "message" as the framing (why you are asking) and, '
			~ 'optionally, "questions" as a list of fields: each is an object with '
			~ '"name" (the key the answer comes back under), "prompt" (what to show '
			~ 'the user), and optionally "type" ("string", "number" or "boolean", '
			~ 'default "string"), "options" (a list of strings to choose between) '
			~ 'and "required" (default true). With no "questions" the user is asked '
			~ 'one free-form question and the answer comes back under "answer". '
			~ 'Answers come back as a JSON object. A user who declines or cancels '
			~ 'is not an error: carry on without the answer or explain why you '
			~ 'cannot.',
		params => {
			message => {
				type        => 'string',
				description => 'What to tell the user about why you are asking',
				required    => True,
			},
			questions => {
				type        => 'array',
				description => 'Optional list of { name, prompt, type?, options?, '
					~ 'required? } objects; omit it to ask one free-form question',
			},
		},
		handler => -> :%args { self!ask(%args) };
}

# === Tool implementation ===

method !ask(%args --> Str:D) {
	my $message = %args<message>;
	die 'Missing required parameter "message"' without $message;
	die 'Parameter "message" must be a string, not ' ~ $message.^name
		if $message ~~ Positional | Associative;
	die 'Parameter "message" must not be empty' unless $message.Str.trim.chars > 0;

	my @form = self!form-for(%args<questions>);
	my %properties = @form[0].Hash;
	my @required = @form[1].list;

	my $answer = $*MCP-REQUEST-CONTEXT.elicit(
		$message.Str,
		:%properties,
		:@required,
		|($!timeout.defined ?? (timeout => $!timeout) !! ()),
	);

	# Refusal is an answer.  Neither of these is an isError result: a model told
	# that its tool failed will try again, and asking a person who has just said
	# no to say no again is the worst thing this tool could do.
	return 'The user declined to answer.' if $answer.declined;
	return 'The user cancelled the request.' if $answer.cancelled;

	# Sorted keys so the same form always renders the same way: the text goes
	# into a model's context, where stability is worth more than insertion order.
	to-json($answer.content, :!pretty, :sorted-keys);
}

# The elicitation form these questions describe: a properties hash and the list
# of names the user must fill in.
method !form-for($questions --> List) {
	# The overwhelmingly common call, and the one a model makes when it just
	# wants to talk: no fields, one free-form answer.
	unless $questions.defined {
		return (
			{ answer => { type => 'string', description => 'Your answer' } },
			['answer',],
		);
	}

	die 'Parameter "questions" must be a list of question objects, not '
		~ $questions.^name
		unless $questions ~~ Positional;

	my @list = $questions.list;
	return ({ answer => { type => 'string', description => 'Your answer' } }, ['answer',])
		unless @list.elems > 0;

	my %properties;
	my @required;
	my %seen;

	for @list.kv -> $index, $question {
		my $ordinal = $index + 1;
		die "Question $ordinal must be an object with a name and a prompt, not a "
			~ $question.^name
			unless $question ~~ Associative;

		my %spec = $question.Hash;
		if %spec.keys.grep({ $_ !(elem) QUESTION-KEYS }).sort -> @unknown {
			die "Question $ordinal has unknown key(s): {@unknown.join(', ')}. "
				~ "Valid keys: {QUESTION-KEYS.keys.sort.join(', ')}";
		}

		my $name = %spec<name>;
		die "Question $ordinal must have a non-empty string \"name\""
			unless $name ~~ Str:D && $name.trim.chars > 0;
		$name = $name.trim;
		die "Question $ordinal reuses the name \"$name\"; answers come back keyed "
			~ 'by name, so every question needs one of its own'
			if %seen{$name}:exists;
		%seen{$name} = True;

		my $type = %spec<type> // 'string';
		die "Question \"$name\" has type \"{$type // ''}\"; a question may be of "
			~ "type {QUESTION-TYPES.keys.sort.join(', ')}"
			unless $type ~~ Str:D && QUESTION-TYPES{$type};

		my %property = type => $type;

		with %spec<prompt> {
			die "The prompt of question \"$name\" must be a string"
				if $_ ~~ Positional | Associative;
			%property<description> = .Str;
		}

		with %spec<options> {
			die "The options of question \"$name\" must be a non-empty list of "
				~ 'non-empty strings'
				unless $_ ~~ Positional && .list.elems > 0
					&& .list.all ~~ Str:D && .list.all.trim.chars > 0;
			die "Question \"$name\" has options, so its type must be string, not \"$type\""
				unless $type eq 'string';
			%property<enum> = .list.map(*.Str).Array;
		}

		%properties{$name} = %property;

		# Required by default: a model that bothered to ask usually needs the
		# answer, and a client renders an optional field as one the user can
		# skip rather than one it can leave out of the form.
		my $wanted = %spec<required> // True;
		die "The \"required\" flag of question \"$name\" must be true or false"
			unless $wanted ~~ Bool;
		@required.push($name) if $wanted;
	}

	(%properties, @required);
}
