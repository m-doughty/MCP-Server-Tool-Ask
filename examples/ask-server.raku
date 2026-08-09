#!/usr/bin/env raku

# An MCP server that can ask its user a question, over Streamable HTTP. Run it:
#
#   raku -I lib -I ../MCP-Server/lib examples/ask-server.raku
#
# ...or, once both distributions are installed, just `raku examples/ask-server.raku`.
#
# HTTP rather than stdio on purpose. This example has two conversations going
# at once -- the protocol with the client, and the fallback question with
# whoever started the server -- and a stdio server has already spent stdin and
# stdout on the first of them. Over HTTP the terminal is free, so the
# :on-elicit fallback below can genuinely use it.
#
# Two ways to see it work:
#
# 1. A client that CAN be asked (elicitation declared in _meta). The call comes
#    back as an input_required result carrying the form, and the client is
#    expected to ask its user and retry with the answers:
#
#      curl -s localhost:8080/mcp \
#        -H 'Content-Type: application/json' \
#        -H 'MCP-Protocol-Version: 2026-07-28' -H 'Mcp-Method: tools/call' \
#        -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
#              "name":"user_ask",
#              "arguments":{"message":"Ready to deploy.","questions":[
#                {"name":"env","prompt":"Which environment?","options":["staging","production"]},
#                {"name":"confirm","prompt":"Go ahead?","type":"boolean"}]},
#              "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
#                       "io.modelcontextprotocol/clientCapabilities":{"elicitation":{"form":{}}}}}}'
#
#    Then send the same request again with a new id, the answers under the keys
#    the server chose, and its requestState echoed back:
#
#      "inputResponses":{"q1":{"action":"accept","content":{"env":"staging","confirm":true}}},
#      "requestState":"mrtr-1-..."
#
# 2. A client that CANNOT be asked (no elicitation capability). Drop the
#    clientCapabilities line above, and the question appears on this terminal
#    instead -- which is exactly how you would wire the tool into a CLI agent
#    or a TUI that owns its own screen.

use MCP::Server;
use MCP::Server::HTTP;

# The local fallback. It receives the same ElicitRequest a client would, and
# returns an ElicitResult: accept with the filled-in content, or decline.
#
# Note what it does NOT do: it never fabricates an answer. A blank required
# field, or end of input, is a decline -- and a decline is a perfectly good
# outcome. The tool reports it to the model as "The user declined to answer."
# rather than as a failure, so the model carries on instead of asking again.
my &ask-on-the-terminal = -> %request {
	my %schema = %request<params><requestedSchema>;
	my %properties = %schema<properties> // {};
	my %required = (%schema<required> // []).list.Set;

	say '';
	say %request<params><message>;

	my %content;
	my Bool $refused = False;

	for %properties.keys.sort -> $name {
		my %property = %properties{$name};
		my $label = %property<description> // $name;
		$label ~= " ({%property<enum>.join('/')})" if %property<enum>;
		$label ~= ' [optional]' unless %required{$name};

		my $reply = prompt("$label: ");
		without $reply {
			# End of input while a question was on the screen.
			$refused = True;
			last;
		}

		$reply = $reply.trim;
		unless $reply.chars {
			# A required field left blank is a refusal; an optional one left
			# blank is simply absent, which is what leaving it out says.
			if %required{$name} {
				$refused = True;
				last;
			}
			next;
		}

		%content{$name} = do given %property<type> // 'string' {
			when 'number'  { +$reply }
			when 'boolean' { so $reply.lc eq any('y', 'yes', 'true', '1') }
			default        { $reply }
		};
	}

	$refused ?? { action => 'decline' } !! { action => 'accept', content => %content };
};

# The toolkit is named, not imported: MCP::Server loads it at runtime, exactly
# as it would from a --config file.
my $server = MCP::Server.new(
	:name<ask-example>,
	:version<1.0>,
	:instructions(
		'Ask the user before guessing. user_ask puts a question in front of the '
		~ 'person you are working for and waits for the answer; a decline is an '
		~ 'answer too, so do not ask the same thing twice.'
	),
	on-elicit => &ask-on-the-terminal,
	# 120 seconds per question: long enough to think about, short enough that a
	# forgotten terminal does not hold the call open for the server's full TTL.
	:tools['Ask' => { timeout => 120 }],
);

MCP::Server::HTTP.new(:$server, :port(8080)).run;
