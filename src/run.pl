#!perl
$\=$/;

#
# Le client du D-MON : une boucle principale tourne toutes les N(180) secondes
# pour envoyer une commande "ALIVE" au serveur.
#

use strict;

use AnyEvent;
use AnyEvent::WebSocket::Client;

use AnyEvent::Open3::Simple;

use JSON;
use Config::JSON;
use REST::Client;

use Centrifugo::Client;

# Timeout des executions en arrière plan (fork)
my $EXECUTION_TIMEOUT=15;
# Intervalle d'envoi des mises à jour des sorties des fork
my $EXEC_UPDATE_INTERVAL=3;
# Intervalle d'envoi d'un message ALIVE au serveur
my $ALIVE_INTERVAL=10;

our $CONFIG_FILE=$ARGV[0] || ( $^O=~/Win/i ? "C:/Windows/Temp/config.json" : "/tmp/config.json" );

our $SERVER_BASE_API=$ENV{"DMON_API"};
our $CENTRIFUGO_WS=$ENV{"CENT_WS"};

die "DMON_API environment variable must be set" unless $SERVER_BASE_API;
die "CENT_WS environment variable must be set" unless $CENTRIFUGO_WS;


my $CENTREON_PLUGINS_DIR=$ENV{"CENTREON_PLUGIN_ROOT"} || '/var/lib/centreon-plugins';
my $CENTREON_PLUGINS='centreon_plugins.pl';

my @ALT_CENTREON_ROOT = ( "../../centreon-plugins/", "../centreon-plugins/", "./centreon-plugins/");

while (@ALT_CENTREON_ROOT && !-f "$CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS") {
	$CENTREON_PLUGINS_DIR = shift @ALT_CENTREON_ROOT;
}

my $API_KEY = "key-123";

my $USER_ID = "Host_User_12345";
my $TIMESTAMP = time();
my $INFO = { class => 'host' };
my $TOKEN;

our $HOST_ID;

our $mainEventLoop;
our $centrifugoClientHandle;

our %execs;
our %execHandles;

# Initialize the monitor
init();

# Ask for a client token
my $AUTH = askForAuth($USER_ID,$API_KEY,$TIMESTAMP);
my $TOKEN = $AUTH->{token};
my $GROUPS = $AUTH->{groups};

# Connects to Centrifugo
connectToCentrifugo( $GROUPS );

# Start the event loop
AnyEvent->condvar->recv;
exit;



###########################################################
#   makeEvent* subs are launching tasks in the event loop

sub connectToCentrifugo {
	my ($groups) = @_;
	
	$centrifugoClientHandle = Centrifugo::Client->new("$CENTRIFUGO_WS/connection/websocket",
		debug => 'true',
		debug_ws => 'false',
		authEndpoint => "$SERVER_BASE_API/auth.php",
		max_alive_period => 49,
		refresh_period => 10,
		retry => 0.5 ,
	#	ws_params => {
	#		ssl_no_verify => 'true',
	#		timeout => 600
	#}
	);

	$centrifugoClientHandle->connect(
		user => $USER_ID,
		timestamp => $TIMESTAMP,
		token => $TOKEN,
		info => encode_json $INFO
	)-> on('message', sub{
		my ($infoRef)=@_;
		# Only read data written into own channel		
		processServerCommand($infoRef->{data}) if $infoRef->{channel}=~/&/;
		# print encode_json $infoRef->{data} if $infoRef->{channel}=~/PING/;
	})-> on('disconnect', sub {
		print "DISCONNECT !!";
		undef $centrifugoClientHandle;
	});

	$centrifugoClientHandle->subscribe( channel => '&' );
	# $centrifugoClientHandle->subscribe( channel => 'PING' );
	foreach my $group (@$groups) {
		# Also subscribe to the private broadcast group channels
		$centrifugoClientHandle->subscribe( channel => '$broadcast_'.$group );
	}

	# For now : loop and ping the server every 10 s
	makeServerEventLoop();
}

# Creates an event to ping the server every X minutes with an "alive" event
sub makeServerEventLoop{
	my $config = openOrCreateConfigFile();
	my $instancesHashRef = $config->get("instances");
	my @instanceIDs = keys %$instancesHashRef;
	my $instanceCheckCount = 1+@instanceIDs;
	my $interval = 1+int( $ALIVE_INTERVAL / $instanceCheckCount ); # TODO : refaire ce calcul
	my $counter = 0;
	$mainEventLoop = AnyEvent->timer(
		after => 0,
		interval => $interval,
		cb => sub {
			if ($counter==0) {
				my $response = sendMessageToServer( 'ALIVE', { 'PERIOD', $interval } );
				processServerJsonCommand($response) if $response;
			} else {
				my $instanceId = $instanceIDs[ $counter-1 ];
				my $cmdline = $config->get("instances/$instanceId");
				processInstance($instanceId, $cmdline);
			}
			$counter++; $counter %= $instanceCheckCount;
		}
	);
}

sub askForAuth {
	my ($user,$apiKey,$timestamp)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	my $data = {};
	$data->{user} = $user;
	$data->{api_key} = $apiKey;
	$data->{timestamp} = $timestamp;
	$data->{info} = $INFO;
	my $POST = encode_json $data;
	$client->POST("/token.php", $POST, { 'Content-type' => 'application/json'});
	print "POST > $POST";
	print "     < (".$client->responseCode().')';
	my $result =$client->responseContent();
	print "     < $result";
	if ($client->responseCode() eq 200) {
		return(decode_json $result);
	}
	print "ERROR < No websocket token (HTTP:".$client->responseCode().')';
}

###########################################################

sub init {
	my $config = openOrCreateConfigFile();	
	$HOST_ID = $config->get('host_id');
	unless ($HOST_ID) {
		$HOST_ID = `hostname`; # Works on Linux AND Win32
		chomp $HOST_ID;
		$config->set('host_id',$HOST_ID);
	}
}

sub openOrCreateConfigFile {
	if (-f $CONFIG_FILE) {
		return Config::JSON->new($CONFIG_FILE);
	} else {
		print STDERR "Config file $CONFIG_FILE not found : Creating...";
		return  Config::JSON->create($CONFIG_FILE);
	}
}

# Sends a notification to the server. The parameter is a HashRef (api-key, host-id and client-id parameters will be added here)
sub sendMessageToServer {
	my ($type, $dataHRef)=@_;
	my $client = REST::Client->new();
	$client->setHost($SERVER_BASE_API);
	my $CLIENT_ID = $centrifugoClientHandle ? $centrifugoClientHandle->client_id() : undef;
	$dataHRef->{ 't' }=$type;
	$dataHRef->{ 'api-key' }=$API_KEY;
	$dataHRef->{ 'client-id' }=$CLIENT_ID;
	$dataHRef->{ 'host-id' }=$HOST_ID;
	my $POST = encode_json $dataHRef;
	$client->POST("/msg.php", $POST, { 'Content-type' => 'application/json'});
	print "$type > $POST";
	print "    < (".$client->responseCode().')';
	my $response=my $resOutput=$client->responseContent();
	if ($response) {
		$resOutput=~s/^/    < /mg;
		print $resOutput;
	}
	return $response;
}

# This takes a command expressed in JSON, sends a ACK to the server, then executes the command and
# sends the result back to the server
# The struct for a command is :
# { "t":"CMD", "id":"CmdID", "cmd":"...", "args":{...} }
# The struct for a ACK/Notification is :
# { "t":"ACK", "id":"CmdID" } or if the JSON is invalid : { "t":"ACK", "id":null, "message":"..." }
# the struct for a result is :
# { "t":"RESULT", "id":"CmdID","status":"0-4", ["message":"...",] ["retcode":"...",] ["STDOUT":"...",] ["STDERR":"..."] }  
#    (status code values are Nagios-compliant : 0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN, 4=PENDING)
#     a value of 4(PENDING) means that the command is NOT finished, and that other messages will follow (partial result)
sub processServerJsonCommand {
	my ($jsonCmd) = shift;
	my $command = 
		eval {
			decode_json $jsonCmd; # TODO : Error here (not JSON) when centrifugo shut down
		} or do {
			my $error = $@;
			sendMessageToServer( 'ACK', { id => undef, message => $error });
			return;
		};
		
	processServerCommand($command);
}

sub getDefaultCommandEnv() {
	my %ENV;
	$ENV{ TIMEOUT } = $EXECUTION_TIMEOUT;
	return %ENV;
}

sub processServerCommand {
	my ($command) = shift;
	# Envoi d'un ACK
	my $cmdId = $command->{id};
	sendMessageToServer( 'ACK', { id => $cmdId });

	# Traitement de la commande
	my $cmd = uc $command->{cmd};
	
	if ('CONNECT' eq $cmd) {
		connectToCentrifugo();	
	}
	elsif ('DISCONNECT' eq $cmd) {
		$centrifugoClientHandle->disconnect() if $centrifugoClientHandle;
	}
	else {
		# List of known commands :   RUN
		if ('RUN' eq $cmd) {
			my $cmdline = $command->{args}->{cmdline};
			
			# Traitement des variables d'environnements ("TIMEOUT=600 ...")
			my %ENV=getDefaultCommandEnv();
			while ($cmdline=~s/^\s*([\w\-]+)=(\S+)\s*//) {
				$ENV{ $1 } = $2;
				print "[$cmdId] ENV{$1}=$2";
			}

			if ($cmdline =~ s/^CHECK\b *//i) {
				processCheckCommand($cmdId, $cmdline, %ENV);
			} else {
				processRunCommand($cmdId, $cmdline, %ENV);
			}
		}
		elsif ('KILL' eq $cmd) {
			my $cmdId = $command->{args}->{cmdId};
			# Kills the pending process
			print "### KILLS cmdId=$cmdId";
			killExecution($cmdId);
		}
		elsif ('REGISTER' eq $cmd) {
			my $cmdline = $command->{args}->{cmdline};
			registerCheckCommand($cmdId, $cmdline);
		}
		elsif ('UNREGISTER' eq $cmd) {
			my $serviceId = $command->{args}->{serviceId};
			unregisterCheckCommand($cmdId, $serviceId);
		}
		elsif ('HELP' eq $cmd) {
			my $cmdline = $command->{args}->{cmdline};
			processHelpOnCheckCommand($cmdId, $cmdline);
		}
		else {
			print "### ERROR : Unknown command : $cmd";
		}
	}
}

# Forks the execution of a system command. The details of the execution are stored in 
# $execs{ $cmdId } = { handle=>..., PID=>... , shortCmd=>..., cmdline=>..., stdout=>[], stderr=>[] }
# and
# $execHandles { $cmdId } = { exec=>..., update=>...}
# (these handle keeps the fork and the update timer alive)
# Input :
#    $type : the type-name of the result that will be sent back to server (RESULT or SERVICE)
#    $cmdId : the ID of the Centrifugo request
#    $shortCmd : the user-friendly commandline (may be shorter that the full one)
#    $cmdLine : the command line to execute
# Output 4 values :
# status (0=OK, 2=Error while running command)
# retCode : return code of the command
# stdout, stderr
sub executeCommand {
	my ($type, $cmdId, $shortCmd, $cmdline, %ENV)=@_;

	my $ipc = AnyEvent::Open3::Simple->new(
		on_start => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $program = shift;    # string
			my @args = @_;          # list of arguments
			print STDERR "EXEC[$cmdId] child PID: ", $proc->pid, ", program: ",$program;
			$execs{$cmdId} = {
				t => $type,
				cmdId => $cmdId,
				PID => $proc->pid,
				cmdline => $shortCmd,
				stdout => [],
				stderr => [],
				status => 0,
				terminated => 0,
				timeoutAt => time()+$ENV{TIMEOUT}
			};
		},
		on_stdout => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $line = shift;       # string
			push @{$execs{$cmdId}->{stdout}}, $line;
			print STDERR "STDOUT[$cmdId]: $line";
		},
		on_stderr => sub {
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $line = shift;       # string
			push @{$execs{$cmdId}->{stderr}}, $line;
			print STDERR "STDERR[$cmdId]: $line";
		},
		on_exit   => sub { # Called when the processes completes, either because it called exit, or if it was killed by a signal.
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $exit_value = shift; # integer
			my $signal = shift;     # integer
			$execs{$cmdId}->{exit_value} = $exit_value;
			$execs{$cmdId}->{signal} = $signal;
			print "EXIT[$cmdId]";
			terminateExecutionAndSendResults($cmdId);
		},
		on_error => sub { # Called when there is an execution error, for example, if you ask to run a program that does not exist. No process is passed in because the process failed to create. 
			my $error = shift;      # the exception thrown by IPC::Open3::open3
			my $program = shift;    # string
			my @args = @_;          # list of arguments
			warn "ERROR[$cmdId]: $error";
			unshift @args, $error;
			$execs{$cmdId}->{status} = 2; # CRITICAL
			$execs{$cmdId}->{stdout} = [];
			$execs{$cmdId}->{stderr} = \@args;
			terminateExecutionAndSendResults($cmdId);
		},
		on_signal => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $signal = shift;     # integer
			print "SIGNAL[$cmdId]: $proc / signal=$signal";
		},
		on_fail => sub { 
			my $proc = shift;       # isa AnyEvent::Open3::Simple::Process
			my $exit_value = shift; # integer
			print "FAIL[$cmdId]: $proc / exit_value=$exit_value";
		},
	);

	# Send result updates on a regular basis
	my $updates = AnyEvent->timer(
		after => 0.2,
		interval => $EXEC_UPDATE_INTERVAL,
		cb => sub {
			# Check Timeout
			if (time()>$execs{$cmdId}->{timeoutAt}) {
				print "TIMEOUT[$cmdId] ENV{TIMEOUT}=".$ENV{TIMEOUT};
				killExecution($cmdId) ;
				undef $execHandles{$cmdId}->{update};
			} else {
				sendResultForExecution($cmdId);
			}
		}
	);
	
	$execHandles{$cmdId} = { handle=> $ipc, update=> $updates };
	$ipc->run($cmdline);
}

sub killExecution{
	my($cmdId)=@_;
	unless($execs{$cmdId}->{terminated}) {
		$execs{$cmdId}->{killed}=1;
		my $pid = $execs{$cmdId}->{PID};
		if ($pid=~/^\d+$/) { # Avoid "Can't kill a non-numeric process ID"
			print "KILL[$cmdId] PID=$pid";
			kill 'KILL', $pid;
		}
	}
}

sub terminateExecutionAndSendResults{
	my($cmdId)=@_;
	unless($execs{$cmdId}->{terminated}) {
		$execs{$cmdId}->{terminated} = 1;
		undef $execHandles{$cmdId}->{handle};
		undef $execHandles{$cmdId}->{update};
		delete $execHandles{$cmdId};
		sendResultForExecution($cmdId);
	}
}

sub sendResultForExecution{
	my($cmdId)=@_;
	sendMessageToServer($execs{$cmdId}->{t}, $execs{$cmdId});
	delete $execs{$cmdId} if $execs{$cmdId}->{terminated};
}

sub sendResultErrorMessage{
	my($cmdId,$message)=@_;
	sendMessageToServer('RESULT', {
		id => $cmdId,
		stdout => [],
		stderr => [ $message ]
	});
}

###################### COMMANDS #######################

sub processRunCommand {
	my ($cmdId, $cmdline, %ENV)=@_;
	print "RUN[$cmdId]:$cmdline";
	executeCommand('RESULT', $cmdId, $cmdline, $cmdline, %ENV);
}

sub processCheckCommand {
	my ($cmdId, $cmdline, %ENV)=@_;
	print "CHECK[$cmdId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS $cmdline";
	executeCommand('RESULT', $cmdId, $cmdline, $fullCmdline, %ENV);
}

sub processInstance {
	my ($iId, $cmdline)=@_;
	print "INSTANCE[$iId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS $cmdline";
	executeCommand('SERVICE', $iId, $cmdline, $fullCmdline);
}

sub processHelpOnCheckCommand {
	my ($cmdId, $cmdline)=@_;
	unless ($cmdline =~ s/^CHECK\b *//i) {
		sendResultErrorMessage($cmdId, "Help only works on CHECK commands");
		return;
	}
	print "HELP[$cmdId]:$cmdline";
	my $fullCmdline="perl $CENTREON_PLUGINS_DIR/$CENTREON_PLUGINS --help $cmdline";
	executeCommand('RESULT', $cmdId, $cmdline, $fullCmdline);
}

sub registerCheckCommand {
	my ($cmdId, $cmdline)=@_;
	print "REGISTER[$cmdId]:$cmdline";
	my $instanceId = $cmdline; $instanceId=~s/\W+/_/g;
	my $config = openOrCreateConfigFile();
	my %instances = $config->addToHash('instances',$instanceId,$cmdline);
	# Envoi du premier résultat (TODO : change to send instanceId)
	processInstance($instanceId,$cmdline);
	makeServerEventLoop();
}

sub unregisterCheckCommand {
	my ($cmdId, $instanceId)=@_;
	print "UNREGISTER[$cmdId]:$instanceId";
	my $config = openOrCreateConfigFile();
	$config->deleteFromHash('instances',$instanceId);
	makeServerEventLoop();
}

