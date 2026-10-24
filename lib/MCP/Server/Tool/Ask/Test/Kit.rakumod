use Test;

use MCP::Server::Protocol;

#|( Shared fixtures for the Ask toolkit tests: a server whose elicitations
    are answered by a script rather than by a person, plus the
    handle-request idiom every tool call is driven through. Deliberately
    does not `use MCP::Server::Tool::Ask` -- t/04 loads the pack dynamically
    and must not have it pulled in behind its back.

    This is test support, not library surface -- it ships inside the dist's
    own namespace (rather than under C<t/lib>) deliberately, so that
    C<zef install>'s test phase precompiles it as part of C<lib/> staging
    before any test file runs. A C<t/lib> CompUnit repo starts cold on a
    fresh C<zef install> and races when parallel test files each pull in
    the fixture's dependency chain, which can fail the install outright;
    moving test support into C<lib/> under a C<::Test> namespace is the
    fleet-wide fix for that failure class. )
unit module MCP::Server::Tool::Ask::Test::Kit;

#| An on-elicit callback that records every question it was asked and answers
#| them from a script, one per call, repeating the last answer once the script
#| runs out.
#|
#| Returns C<< { hook => &callback, asked => @requests } >> rather than a list:
#| a list assignment would copy the array and the caller would watch a snapshot
#| fill up with nothing.  The answers are taken as one Array parameter for the
#| same family of reasons -- a slurpy would flatten an ElicitResult hash into
#| pairs.
sub scripted(@answers --> Hash) is export {
	my @asked;
	my $lock = Lock.new;
	my $next = 0;

	my &hook = -> %request {
		$lock.protect: {
			@asked.push(%request);
			my $index = $next min (@answers.elems - 1);
			$next++;
			@answers.elems > 0 ?? @answers[$index] !! { action => 'decline' };
		};
	};

	{ hook => &hook, asked => @asked };
}

sub call-tool($server, Str:D $name, %arguments --> Hash) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 1, method => 'tools/call',
		params => { name => $name, arguments => %arguments },
	});
}

#| A modern-era request body.  Client capabilities travel in _meta on every
#| request, which is what tells the server it may ask this client things.
sub modern-msg($id, Str:D $method, %params, Bool:D :$caps = True --> Hash) is export {
	my %meta = (META-PROTOCOL-VERSION) => MODERN-PROTOCOL-VERSION;
	%meta{META-CLIENT-CAPABILITIES} = { elicitation => { form => {} } } if $caps;

	my %full = %params;
	%full<_meta> = %meta;
	{ jsonrpc => '2.0', :$id, :$method, params => %full };
}

sub result-text(%response --> Str) is export {
	%response<result><content>[0]<text> // '';
}

sub result-errored(%response --> Bool:D) is export {
	so %response<result><isError>;
}

sub tool-names($server --> List) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 99, method => 'tools/list',
	})<result><tools>.map(*<name>).sort.list;
}

#| The inputSchema the server advertises for one tool.
sub tool-schema($server, Str:D $name --> Hash) is export {
	$server.handle-request({
		jsonrpc => '2.0', id => 98, method => 'tools/list',
	})<result><tools>.first({ $_<name> eq $name })<inputSchema>;
}

#| Assert that a tool call came back as an error result carrying $needle.
sub errors-with($server, Str:D $name, %arguments, Str:D $needle, Str:D $desc) is export {
	my %response = call-tool($server, $name, %arguments);
	my $text     = result-text(%response);
	my $matched  = result-errored(%response) && $text.contains($needle);
	ok $matched, $desc;
	diag "result was: {%response<result>.raku}" unless $matched;
}

#| Assert that &code throws something whose message contains $needle.
sub dies-with(&code, Str:D $needle, Str:D $desc) is export {
	my Str $message;
	{
		code();
		CATCH { default { $message = .message } }
	}
	my $matched = $message.defined && $message.contains($needle);
	ok $matched, $desc;
	diag "message was: {$message // '(nothing thrown)'}" unless $matched;
}
