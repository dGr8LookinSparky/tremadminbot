#!/usr/bin/perl
#    TremAdminBot: A bot that provides some helper functions for Tremulous server administration
#    By Chris "Lakitu7" Schwarz, lakitu7@mercenariesguild.net
#
#    This file is part of TremAdminBot
#
#    TremAdminBot is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    TremAdminBot is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with TremAdminBot.  If not, see <http://www.gnu.org/licenses/>.

use common::sense;
use DBI;
use Socket 1.93 qw/:DEFAULT :addrinfo/;
use Data::Dumper;
use enum;
use FileHandle;
use File::ReadBackwards;
use Fcntl ':seek';
use File::Spec::Functions 'catfile';
# also uses
# Carp;
# Time::HiRes 'time';

use enum qw( CON_DISCONNECTED CON_CONNECTING CON_CONNECTED );
use enum qw( SEND_DISABLE SEND_PIPE SEND_RCON SEND_SCREEN );
use enum qw( DEM_KICK DEM_BAN DEM_MUTE DEM_DENYBUILD );
use enum qw( LOG_TIME LOG_TYPE LOG_ARG );
use enum qw( PRIO_NOW=-1 PRIO_COMMAND PRIO_CONSOLE PRIO_GLOBAL PRIO_USER );

# config: best to leave these defaults alone and set each var you want to override from default in config.cfg
#         e.g. if you want to change $logpath, put a line that says
#              $logpath = "/somewherelse/games.log";
#              in config.cfg

# Path to games.log
our $logpath = "games.log";

# Path to admin.dat
our $adminpath = "admin.dat";

# Where do we store the database
our $dbfile = "bot.db";

# Are we reading from the whole logfile to populate the db? Generally this is 0
our $backlog = 0;

# How should we send output responses back to the server?
#  SEND_DISABLE: Do not send output responses back to the server.
#  SEND_PIPE:    Write to a pipefile, as configured by the com_pipefile option. Best option if available.
#                Fast and robust.
#  SEND_RCON:    Use rcon
#                The only option that can get a response back from commands, but we don't use that anyway.
#                Slow and shows up in log files as rcon usage.
#  SEND_SCREEN:  Send a command to the screen session tremded is running in.
#                Very annoying if humans also attach to and use screen.
our $sendMethod = SEND_PIPE;

# rcon password, only used for SEND_RCON
our $rcpass = "myrconpassword";

# server ip, only used for SEND_RCON
our $ip = "127.0.0.1";

# server port, only used for SEND_RCON
our $port = "30720";

#  path to communication pipe to write to, only used for SEND_PIPE
our $pipefilePath = ".tremded_pipe";

# path to screen binary, only used for SEND_SCREEN
# leave default in most cases
our $screenPath = "screen";

# name of screen session, only used for SEND_SCREEN
# if your server startup script looks something like 'screen -S tremded ..."
# then 'tremded' is what you put here: i.e. whatever is after the -S
our $screenName = "tremded";

# name of screen window, only used for SEND_SCREEN
# the default '0' sends to whatever is in the first window in that screen
# session
our $screenWindow = "0";

# only show demerits over the past x days (or forever if <= 0)
our $demeritdays = 90;

do 'config.cfg';
# ------------ CONFIG STUFF ENDS HERE. DON'T MODIFY AFTER THIS OR ELSE!! ----------------


$SIG{INT} = sub
{
  cleanup();
  exit;
};
$SIG{__DIE__} = \&errorHandler;

print( "TremAdminBot: A bot that provides some helper functions for Tremulous server administration\n" );
print( "TremAdminBot Copyright (C) 2011 Christopher Schwarz (lakitu7\@mercenariesguild.net)\n" );
print( "This program comes with ABSOLUTELY NO WARRANTY.\n" );
print( "This is free software, and you are welcome to redistribute it under certain conditions.\n" );
print( "For details, see gpl.txt\n" );
print( "-------------------------------------------------------------------------------------------\n" );

my $db;

sub initdb
{
  $db = DBI->connect( "dbi:SQLite:${dbfile}", "", "", { RaiseError => 1, AutoCommit => 0 } ) or die( "Database error: " . $DBI::errstr );

  # uncomment to dump all db activity to stdout
  #`$db->{TraceLevel} = 1;

  # create tables if they do not exist already
  {
    my @tables;

    @tables = $db->tables( undef, undef, "users", undef );
    if( !scalar @tables )
    {
      $db->do( "CREATE TABLE users( userID INTEGER PRIMARY KEY, name TEXT, GUID TEXT, useCount INTEGER, seenTime DATETIME, IP TEXT, city TEXT, region TEXT, country TEXT )" );
      $db->do( "CREATE INDEX guidIndex on users( GUID )" );
      $db->do( "INSERT INTO users ( name, GUID, useCount ) VALUES ( \'console\', \'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\', 0 )" );
    }

    @tables = $db->tables( undef, undef, "names", undef );
    if( !scalar @tables )
    {
      $db->do( "CREATE TABLE names( nameID INTEGER PRIMARY KEY, name TEXT, nameColored TEXT, userID INTEGER, useCount INTEGER, FOREIGN KEY( userID ) REFERENCES users( userID ) )" );
      $db->do( "CREATE INDEX nameIndex on names( name )" );
      $db->do( "INSERT INTO names ( name, nameColored, userID, useCount ) VALUES ( \'console\', \'console\', 1, 0 )" );
    }

    @tables = $db->tables( undef, undef, "memos", undef );
    if( !scalar @tables )
    {
      $db->do( "CREATE TABLE memos( memoID INTEGER PRIMARY KEY, userID INTEGER, sentBy INTEGER, sentTime DATETIME, readTime DATETIME, msg TEXT, FOREIGN KEY( userID ) REFERENCES users( userID ), FOREIGN KEY( sentby ) REFERENCES users( userID ) )" ) if( !scalar @tables );
    }

    @tables = $db->tables( undef, undef, "demerits", undef );
    if( !scalar @tables )
    {
      $db->do( "CREATE TABLE demerits( demeritID INTEGER PRIMARY KEY, userID INTEGER, demeritType INTEGER, admin INTEGER, reason TEXT, timeStamp DATETIME, duration INTEGER, IP TEXT, FOREIGN KEY( userID ) REFERENCES users( userID ), FOREIGN KEY( admin ) REFERENCES users( userID ) )" ) if( !scalar @tables );
    }
  }
}

# allocate
use constant MAX_CLIENTS => 64;
our @connectedUsers;
our @admins;
for( my $i = 0; $i < MAX_CLIENTS; $i++ )
{
  push( @connectedUsers, { 'connected' => CON_DISCONNECTED } );
}
# console gets the last slot so -1 works
$connectedUsers[ MAX_CLIENTS ] =
{
  'connected' => CON_DISCONNECTED,
  'name' => 'console',
  'nameColored' => 'console',
  'aname' => 'console',
  'alevel' => 99,
  'GUID' => 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
  'IP' => '127.0.0.1',
  'userID' => 1,
  'slot' => -1
};
my $linesProcessed = -1;

my $servertsstr = "";

####
# In general, colons (followed by a space or end of line) separate log parts
# However, colons may be literals in a few cases which have to be special-cased
# for regular expression-based parsing:
#	IPv6 addresses contain colons (in brackets)
#	Names can contain colons (in quotes)
#	Datetimes contain colons (immediately following a digit)
# Since the time part at the beginning of a line immediately precedes the log
# type, but they are not separated by a colon, time must be removed before this
# regex is used
my $main = qr/((?>\[[^\]]*\]|"[^"]*"|\d+[ \/:]|[^":]+)+)(?:: |$)?/;
#clientnum "currentname"
#"adminname" [adminlevel] (guid)
#flags
my $adminauth_0 = qr/^(-?\d+) "([^"]*)"$/;
my $adminauth_1 = qr/^"([^"]*)" \[(-?\d+)\] \(([^\)]*)\)$/;
#clientnum "currentname" "adminname" [adminlevel] (guid)
#flags
my $adminauth = qr/^(-?\d+) "([^"]*)" "([^"]*)" \[(-?\d+)\] \(([^\)]*)\)$/;
#clientnum "currentname" ("adminname") [adminlevel]
#command args
my $admincmd = qr/^(-?\d+) "([^"]*)" \("([^"]*)"\) \[(-?\d+)\]$/;
my $adminargs = qr/("[^"]*"|\S+)/;
#ok|fail
#clientnum "currentname" "adminname" [adminlevel] (guid)
#command
#args
my $adminexec = qr/^(-?\d+) "([^"]*)" "([^"]*)" \[(-?\d+)\] \(([^\)]*)\)$/;
#number (guid) "name"
my $admintarget = qr/^(-?\d+) \(([^\)]*)\) "([^"]*)"$/;
####

my $clientConnectRegExp = qr/^(\d+) \[(.*)\] \((\w+)\) \"(.*)\" \"(.*)\"/;
my $clientDisconnectRegExp = qr/^(\d+)/;
my $clientBeginRegExp = qr/^(\d+)/;
my $clientRenameRegExp = qr/^(\d+) \[(.*)\] \((\w+)\) \"(.*)\" -> \"(.*)\" \"(.*)\"/;

my $startupBacklog = 0;

my $addr;
my @send;
sub sendPipe
{
  my $msg = $_[ 0 ];
  local $SIG{ 'PIPE' } = sub
  {
    warn( "received sigpipe; trying to reopen pipe file\n" );
    initmsg();
    # prevent the original message from being lost
    @_ = $msg;
    goto \&sendPipe;
  };
  print( SENDPIPE "$msg\n" );
}
$send[ SEND_DISABLE ] = sub{};
$send[ SEND_PIPE ] = \&sendPipe;
$send[ SEND_RCON ] = sub
{
  send( RCON, "\xff\xff\xff\xffrcon $rcpass $_[ 0 ]", 0, $addr->{ addr } );
};
$send[ SEND_SCREEN ] = sub
{
  my @cmd = ( $screenPath );
  push( @cmd, '-S', $screenName ) if( $screenName ne '' );
  push( @cmd, '-p', $screenWindow ) if( $screenWindow ne '' );
  push( @cmd, qw/-q -X stuff/, "\b" x 30 . $_[ 0 ] . "\n" );
  warn( "screen returned $?\n" ) if( system( @cmd ) != 0 );
};
my $sendq;

my %cmds;
sub loadcmds
{
  my( $sub, $cmd );
  %cmds = ();
  return unless( opendir( CMD, 'cmds' ) );
  print "Loading admin command handlers...\n";
  foreach( readdir( CMD ) )
  {
    next unless( /^(.+)\.pl$/i );
    $cmd = lc( $1 );
    $sub = do( catfile( 'cmds', $_ ) );
    unless( $sub )
    {
      warn( "$cmd: ", $@ || $!, "\n" );
      next;
    }
    $cmds{ $cmd } = $sub;
    print " Loaded: ${cmd}\n";
  }
  closedir( CMD );
  print "done\n";
}

# this makes it much easier to send signals
$0 = __FILE__;

# returns time (in seconds), followed by log sections ([1] is type)
sub splitLine( $ )
{
  my $line = $_[0];
  return unless( $line =~ s/^ *(\d+):([0-5]\d) // );
  return( $1 * 60 + $2, $line =~ /$main/go );
}

# "name" -> name, [address] -> address, (guid) -> guid
sub unenclose( $ )
{
  my $fc = substr( $_[ 0 ], 0, 1 );
  return $fc eq '"' || $fc eq '[' || $fc eq '(' ?
    substr( $_[ 0 ], 1, length( $_[ 0 ] ) - 2 ) :
    $_[ 0 ];
}

# these are generally usable like clients
sub loadadmins
{
  unless( open( ADMIN, '<', $adminpath ) )
  {
    warn( "could not open $adminpath: $!\n" );
    return;
  }

  for( my $i = 0; $i < MAX_CLIENTS; $i++ )
  {
    $connectedUsers[ $i ]{ 'aname' } = '';
    $connectedUsers[ $i ]{ 'alevel' } = 0;
  }

  @admins = ();
  while( my $line = <ADMIN> )
  {
    next unless( $line && $line =~ /^\[admin]$/ );
    my $admin = {};
    while( $line = <ADMIN> )
    {
      last unless( my ( $key, $val ) = $line =~ /\s*(\w+)\s+=\s+((?<=")[^"]*(?="?)|[^\n]+)/ );
      $admin->{ lc( $key ) } = $val;
    }
    if( exists( $admin->{ 'level' } ) && exists( $admin->{ 'name' } ) )
    {
      push( @admins, {
        'connected' => CON_DISCONNECTED,
        'name' => $admin->{ 'name' },
        'nameColored' => $admin->{ 'name' },
        'aname' => $admin->{ 'name' },
        'alevel' => $admin->{ 'level' },
        'GUID' => $admin->{ 'guid' }
      });
      $admins[ -1 ]->{ 'name' } =~ s/\^[\da-z]//gi; #decolor

      # Copy info to @connectedUsers if user is connected
      my $target = getuser( $admin->{ 'guid' } );
      if( $target )
      {
        $target->{ 'alevel' } = $admin->{ 'level' };
        $target->{ 'aname' } = $admin->{ 'name' };
      }
    }
    redo if( $line ne '' ); #necessary if input is malformed in some way by manual editing
  }
  close( ADMIN );

  @admins = sort { $b->{ 'alevel' } <=> $a->{ 'alevel' } } @admins;
  for( my $i = 0; $i < @admins; $i++ )
  {
    $admins[ $i ]{ 'slot' } = MAX_CLIENTS + $i;
  }
}

my( $dev, $inode );
sub openLog
{
  my $tries = $_[ 0 ] || 1;
  while( $tries-- > 0 )
  {
    last if( open( FILE, "<", $logpath ) );
    sleep( 1 ) if( $tries );
  }
  die( "open logfile failed: ${logpath}" ) unless( defined( fileno( FILE ) ) );

  if( !$backlog )
  {
    ( $dev, $inode ) = stat( FILE );

    # Seek back to the start of the current game
    my $bw = File::ReadBackwards->new( $logpath );
    my $seekPos = 0;
    $startupBacklog = 1;

    while( defined( my $line = $bw->readline( ) ) )
    {
      if( my @parts = splitLine( $line ) )
      {
        if( $parts[ LOG_TYPE ] eq 'InitGame' )
        {
          $seekPos = $bw->tell( );
          last( );
        }
      }
    }

    if( $seekPos )
    {
      seek( FILE, $seekPos, SEEK_SET ) or die( "seek fail" );
    }
    else
    {
      seek( FILE, 0, SEEK_END ) or die( "seek fail" );
    }
  }
}

sub initmsg
{
  $sendq = CommandQueue->new(
    'method' => $send[ $sendMethod ],
    'bucketrate' => $sendMethod == SEND_RCON ? 1000 : 1
  );

  if( $sendMethod == SEND_PIPE )
  {
    die( "${pipefilePath} does not exist or is not a pipe. Is tremded running?" )
      if( !-p( $pipefilePath ) );
    open( SENDPIPE, ">", $pipefilePath );
    SENDPIPE->autoflush( 1 );
  }
  elsif( $sendMethod == SEND_RCON )
  {
    ( my $err, $addr ) = getaddrinfo(
      $ip,
      $port,
      {
        protocol => Socket::IPPROTO_UDP,
        socktype => SOCK_DGRAM
      }
    );
    die( "Can't resolve $ip\n" ) if( $err || !$addr );
    print "Server rcon ip $ip resolved as ",
      ( getnameinfo( $addr->{ addr }, NI_NUMERICHOST ) )[ 1 ], "\n";
    socket( RCON, $addr->{ family }, SOCK_DGRAM, $addr->{ protocol } );
    # the entire packet is read in a 1024 length buffer
    $sendq->set( 'maxlength', 1023 - 6 - length( $rcpass ) );
  }
}

sub hup
{
  close( RCON ) if( !$backlog && $sendMethod == SEND_RCON );
  require( 'config.cfg' );
  cleanup() if( $db );
  initdb;
  if( !$backlog )
  {
    initmsg;
    $sendq->set( 'method', $send[ $sendMethod ] );
    $sendq->set( 'bucketrate', $sendMethod == SEND_RCON ? 1000 : 1 );
    loadcmds;
  }
  else
  {
    print( "Processing backlog on file ${logpath}. This will take a long time for large files.\n" );
  }
  openLog;
}
$SIG{ 'HUP' } = \&hup;
hup;

my $ingame;
while( 1 )
{
  $sendq->send unless( $backlog );
  if( my $line = <FILE> )
  {
    chomp $line;
    #`print "${line}\n";

    my $timestamp = timestamp( );

    $linesProcessed++;

    # Committing periodically instead of using autocommit speeds the db up massively
    if( $linesProcessed % 100 == 0 )
    {
      $db->commit( );
    }

    if( $backlog && $linesProcessed % 1000 == 0 )
    {
      print( "Processed ${linesProcessed} lines. Current timestamp: ${timestamp}\r" );
    }

    if( my @args = splitLine( $line ) )
    {
      my( $slot, $ip, $guid, $name, $name2, $name3, $level );
      if( $args[ LOG_TYPE ] eq "ShutdownGame" )
      {
        $ingame = 0;
      }
      elsif( $args[ LOG_TYPE ] eq "InitGame" )
      {
        $ingame = 1;
        # this is only necessary in "live" mode since "readconfig" is sent when
        # the backlog is cleared
        loadadmins unless( $backlog || $startupBacklog );
      }
      elsif( $args[ LOG_TYPE ] eq "ClientConnect" )
      {
        unless( ( $slot, $ip, $guid, $name, $name2 ) = $args[ LOG_ARG + 0 ] =~ $clientConnectRegExp )
        {
          print( "Parse failure on @args\n" );
          next;
        }

        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTING;
        $connectedUsers[ $slot ]{ 'name' } = $name;
        $connectedUsers[ $slot ]{ 'nameColored' } = $name2;
        $connectedUsers[ $slot ]{ 'IP' } = unenclose( $ip ) || '127.0.0.1';
        $connectedUsers[ $slot ]{ 'GUID' } = unenclose( $guid );
        $connectedUsers[ $slot ]{ 'aname' } = "";
        $connectedUsers[ $slot ]{ 'alevel' } = 0;
        $connectedUsers[ $slot ]{ 'slot' } = $slot;

        updateUsers( $timestamp, $slot );

        # if their rapsheet is too long, warn connected admins
        my @demerits = demerits( 'userID', $connectedUsers[ $slot ]{ 'userID' } );
        if( $demerits[ DEM_KICK ] + $demerits[ DEM_BAN ] > 3 || $demerits[ DEM_DENYBUILD ] > 5 )
        {
          sendconsole( "a $name may be a troublemaker: Kicks: $demerits[ DEM_KICK ] Bans: $demerits[ DEM_BAN ] Mutes: $demerits[ DEM_MUTE ] Denybuilds: $demerits[ DEM_DENYBUILD ]", PRIO_GLOBAL );
        }
      }
      elsif( $args[ LOG_TYPE ] eq "ClientDisconnect" )
      {
        unless( ( $slot ) = $args[ LOG_ARG + 0 ] =~ $clientDisconnectRegExp )
        {
          print( "Parse failure on @args\n" );
          next;
        }
        $connectedUsers[ $slot ]{ 'connected' } = CON_DISCONNECTED;
      }
      elsif( $args[ LOG_TYPE ] eq "ClientBegin" )
      {
        unless( ( $slot ) = $args[ LOG_ARG + 0 ] =~ $clientBeginRegExp )
        {
          print( "Parse failure on @args\n" );
          next;
        }
        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTED;

        next if( $startupBacklog );

        memocheck( $slot, $timestamp );

      }
      elsif( $args[ LOG_TYPE ] eq "AdminAuth" )
      {
        unless( ( $slot, $name, $name2, $level, $guid ) = $args[ LOG_ARG + 0 ] =~ $adminauth )
        {
          print( "Parse failure on @args\n" );
          next;
        }

        $connectedUsers[ $slot ]{ 'aname' } = $name2;
        $connectedUsers[ $slot ]{ 'alevel' } = $level;
        $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        my $userID = $connectedUsers[ $slot ]{ 'userID' };

        my $anameq = $db->quote( $name );

        $db->do( "UPDATE users SET name=${anameq} WHERE userID=${userID}" );
      }
      elsif( $args[ LOG_TYPE ] eq "ClientRename" )
      {
        unless( ( $slot, $ip, $guid, $name3, $name, $name2 ) = $args[ LOG_ARG + 0 ] =~ $clientRenameRegExp )
        {
          print( "Parse failure on @args\n" );
          next;
        }
        $connectedUsers[ $slot ]{ 'previousName' } = $name3;
        $connectedUsers[ $slot ]{ 'name' } = $name;
        $connectedUsers[ $slot ]{ 'nameColored' } = $name2;

        updateNames( $slot );
      }
      elsif( $args[ LOG_TYPE ] eq "RealTime" )
      {
        $servertsstr = $args[ LOG_ARG + 0 ];
      }
      elsif( $args[ LOG_TYPE ] eq "AdminExec" )
      {
        next if( $args[ LOG_ARG + 0 ] ne 'ok' );
        unless( ( $slot, $name, $name2, $level, $guid ) = $args[ LOG_ARG + 1 ] =~ $adminexec )
        {
          print( "Parse failure on @args\n" );
          next;
        }

        my $nameq = $db->quote( $name );
        my $acmd = lc( $args[ LOG_ARG + 2 ] );
        my @acmdargs = @args[ LOG_ARG + 3 .. $#args ];

        my $userID = $connectedUsers[ $slot ]{ 'userID' };
        # should only be blank for console
        $guid ||= 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX';

        my( $targslot, $targGUID, $targName );

        # Commands after this point are not interacted with in startupBacklog conditions
        next if( $startupBacklog );

        if( exists( $cmds{ $acmd } ) )
        {
          next if( $backlog );

          @acmdargs = $acmdargs[ 0 ] =~ /$adminargs/go;
          print "Cmd: $connectedUsers[ $slot ]{ name } /$acmd @acmdargs\n";
          $cmds{ $acmd }( $connectedUsers[ $slot ], \@acmdargs, $timestamp, $db );
        }
        elsif( $acmd eq "readconfig" )
        {
          loadadmins unless( $backlog );
        }
        elsif( $acmd eq "setlevel" )
        {
          next if( $backlog );

          unless( ( $level, $guid, $name ) = $acmdargs[ 0 ] =~ $admintarget )
          {
            print( "Parse failure on AdminExec @acmdargs\n" );
            next;
          }
          # remove the "s
          $name = unenclose( $name );
          my $admin = getadmin( $guid );
          if( $admin )
          {
            $admin->{ 'alevel' } = $level;
            $admin->{ 'name' } = $name;
            $admin->{ 'aname' } = $name;
          }
          else
          {
            my $target = getuser( $guid );
            unless( $target )
            {
              print "setlevel with invalid target (this should never happen)\n" if( !$startupBacklog );
              next;
            }
            $admin = {
              'connected' => CON_DISCONNECTED,
              'name' => $name,
              'nameColored' => $target->{ 'nameColored' },
              'aname' => $name,
              'alevel' => $level,
              'GUID' => $guid,
              'slot' => MAX_CLIENTS + @admins
            };
            $target->{ 'alevel' } = $level;
            $target->{ 'aname' } = $name;
            push( @admins, $admin );
          }
        }
        elsif( $acmd eq "kick" )
        {
          unless( ( $targslot, $targGUID, $targName ) = $acmdargs[ 0 ] =~ $admintarget )
          {
            print( "Parse failure on AdminExec @acmdargs\n" );
            next;
          }
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          my $reasonq = $db->quote( $acmdargs[ 1 ] );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip, reason) VALUES ( ${targUserID}, " . DEM_KICK . ", ${userID}, ${timestamp}, ${targIPq}, ${reasonq} )" );
        }
        elsif( $acmd eq "ban" )
        {
          my $duration;
          unless( ( $duration, $targGUID, $targName ) = $acmdargs[ 0 ] =~ $admintarget )
          {
            print( "Parse failure on AdminExec @acmdargs\n" );
            next;
          }

          my $targUserID = userIDFromGUID( $targGUID );
          if( $targUserID == -1 )
          {
            print( "Error: ban on unknown guid ${targGUID}\n" );
            next;
          }

          my $reasonq = $db->quote( $acmdargs[ 1 ] );
          # there might be more than 1
          my $targIPq = $db->quote( $acmdargs[ 2 ] );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip, reason, duration) VALUES ( ${targUserID}, " . DEM_BAN . ", ${userID}, ${timestamp}, ${targIPq}, ${reasonq}, $duration )" );
        }
        elsif( $acmd eq "mute" )
        {
          unless( ( $targslot, $targGUID, $targName ) = $acmdargs[ 0 ] =~ $admintarget )
          {
            print( "Parse failure on AdminExec @acmdargs\n" );
            next;
          }
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip) VALUES ( ${targUserID}, " . DEM_MUTE . ", ${userID}, ${timestamp}, ${targIPq} )" );
        }
        elsif( $acmd eq "denybuild" )
        {
          unless( ( $targslot, $targGUID, $targName ) = $acmdargs[ 0 ] =~ $admintarget )
          {
            print( "Parse failure on AdminExec @acmdargs\n" );
            next;
          }
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip) VALUES ( ${targUserID}, " . DEM_DENYBUILD . ", ${userID}, ${timestamp}, ${targIPq} )" );
        }
      }
      # Unused at present but left here for if other people want to screw with it
      #`elsif( $args[ LOG_TYPE ] eq "Say" || $args[ LOG_TYPE ] eq "SayTeam" || $args[ LOG_TYPE ] eq "AdminMsg" )
      #`{
        #`$args[ LOG_ARGS + 0 ] =~ $adminauth_0;
        #`my $slot = $1;
        #`my $player = $2;
        #`my $said = $args[ LOG_ARGS + 1 ];
        #`if( $said =~ /hi console/i )
        #`{
          #`replyToPlayer( $slot, "Hi ${player}!" );
        #`}
      #`}
    }
  }
  else
  {
    if( $backlog )
    {
      print "\nEnd of backlog\n";
      exit;
    }

    if( $startupBacklog )
    {
      $startupBacklog = 0;

      # do a readconfig on startup to see that admins are sorted and up to date
      sendconsole( "readconfig", PRIO_COMMAND );

      print( "Finished startup routines. Watching logfile:\n" );
    }

    # the log might have been moved
    my @stat = stat( $logpath );
    if( !$ingame && ( !@stat || $stat[ 0 ] != $dev || $stat[ 1 ] != $inode ) )
    {
      close( FILE );
      print( "Logfile moved, reopening\n" );
      # retry for up to 3 seconds before giving up
      openLog( 3 );
    }
    else
    {
      seek( FILE, 0, SEEK_CUR );
      select( undef, undef, undef, $sendq->get( 'period' ) );
    }
  }
}

sub replyToPlayer
{
  my( $userSlot, $string ) = @_;
  $string =~ tr/"//d;
  $userSlot = $userSlot->{ 'slot' } if( ref( $userSlot ) );

  if( $userSlot >= 0 )
  {
    sendconsole( "pr ${userSlot} \"${string}\"", PRIO_USER );
  }
  else
  {
    sendconsole( "echo \"${string}\"", PRIO_CONSOLE );
  }
}

sub printToPlayers
{
  my( $string ) = @_;
  $string =~ tr/"//d;
  sendconsole( "pr -1 \"${string}\"", PRIO_GLOBAL );
}

# priorities:
# 0 commands
# 1 console messages
# 2 global announcements
# 3 user messages
sub sendconsole
{
  my( $string, $priority ) = @_;
  return if( $backlog || $startupBacklog );

  $string =~ tr/[\13\15]//d;

  if( $sendMethod < 0 || $sendMethod >= @send )
  {
    die "Invalid $sendMethod configured";
  }

  $priority = PRIO_USER unless( defined( $priority ) );
  $sendq->enqueue( $string, $priority );
}

sub updateUsers
{
  my( $timestamp, $slot ) = @_;
  my $guid = $connectedUsers[ $slot ]{ 'GUID' };
  my $guidq = $db->quote( $guid );
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $ip = $connectedUsers[ $slot ]{ 'IP' };
  my $ipq = $db->quote( $ip );

  my $usersq = $db->prepare( "SELECT userID FROM users WHERE GUID = ${guidq} LIMIT 1" );
  $usersq->execute;

  my $user;

  if( $user = $usersq->fetchrow_hashref( ) )
  {
    $db->do( "UPDATE users SET name=$nameq, useCount=useCount+1, seenTime=$timestamp, ip=$ipq WHERE userID=$user->{ userID }" );
  }
  else
  {
    my $city = '';
    my $region = '';
    my $country = '';
    my $gip;
    if( ( $gip = main->can( 'getrecord' ) ) && ( $gip = $gip->( $ip ) ) )
    {
      $city = $gip->city;
      $region = $gip->region;
      $country = $gip->country_name;
    }
    $city = $db->quote( $city );
    $region = $db->quote( $region );
    $country = $db->quote( $country );

    $db->do( "INSERT INTO users ( name, GUID, useCount, seenTime, IP, city, region, country ) VALUES ( ${nameq}, ${guidq}, 1, ${timestamp}, ${ipq}, ${city}, ${region}, ${country} )" );
    $usersq->execute;
    $user = $usersq->fetchrow_hashref( );
  }

  my $userID = $user->{ 'userID' };
  $connectedUsers[ $slot ]{ 'userID' } = $userID;

  return if( $startupBacklog );

  updateNames( $slot );
}

sub updateNames
{
  my( $slot ) = @_;
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $namec = $connectedUsers[ $slot ]{ 'nameColored' };
  my $namecq = $db->quote( $namec );
  my $userID = $connectedUsers[ $slot ]{ 'userID' };
  my $nameID = "-1";

  my $namesq = $db->prepare( "SELECT nameID FROM names WHERE name = ${nameq} AND userID = $userID LIMIT 1" );
  $namesq->execute;

  my $namesref;

  if( my $ref = $namesq->fetchrow_hashref( ) )
  {
    $nameID = $ref->{nameID};
    $db->do( "UPDATE names SET useCount=useCount+1 WHERE nameID=$nameID" );
  }
  else
  {
    $db->do( "INSERT INTO names ( name, nameColored, userID, useCount ) VALUES ( ${nameq}, ${namecq}, ${userID}, 1 )" );
    $nameID = $db->last_insert_id( undef, undef, "names", "nameID" );
  }
}

sub memocheck
{
  my( $slot, $timestamp ) = @_;
  my $name = $connectedUsers[ $slot ]{ 'name' };
  my $userID = $connectedUsers[ $slot ]{ 'userID' };

  my $q = $db->prepare( "SELECT COUNT(1) FROM memos WHERE memos.userID = ${userID} AND memos.readTime IS NULL" );
  $q->execute;

  my $ref = $q->fetchrow_hashref( );
  my $count = $ref->{ 'COUNT(1)' };

  replyToPlayer( $connectedUsers[ $slot ], "You have ${count} new memos. Use /memo list to read." ) if( $count > 0 );

}

sub demerits
{
  my( $type, $value, $err ) = @_;
  my $r = int( $demeritdays );
  $r = $r > 0 ? "timeStamp >= datetime( 'now', '-$r days' ) AND" : "";
  my $dst;
  if( $type eq 'SUBNET' )
  {
    # this sucks
    if( $value =~ s/^((?:\d{1,3}\.){3})\d{1,3}$/$1%/ )
    {
      $dst = $db->prepare( "SELECT demeritType FROM demerits WHERE $r IP LIKE ?" );
    }
    else
    {
      $$err = 'SUBNET matches only work with IPv4 addresses' if( $err );
      return;
    }
  }
  else
  {
    # ? is treated as a string (which userID is not), but that's probably okay
    $dst = $db->prepare( "SELECT demeritType FROM demerits WHERE $r $type = ?" );
  }
  unless( $dst )
  {
    $$err = 'database error' if( $err );
    return;
  }
  unless( $dst->execute( $value ) )
  {
    $$err = 'database error: ' . $dst->errstr if( $err );
    return;
  }
  my @demerits = ( 0, 0, 0, 0 );
  while( my $dem = $dst->fetch )
  {
    $demerits[ $dem->[ 0 ] ]++;
  }
  return @demerits;
}

sub getadmin
{
  my $guid = lc( $_[ 0 ] );
  foreach my $admin ( @admins )
  {
    return $admin if( lc( $admin->{ 'GUID' } ) eq $guid );
  }
  return;
}

sub cleanstring
{
  ( my $str = lc( $_[ 0 ] ) ) =~ s/[^\da-z]//gi;
  return $str;
}

sub findadmin
{
  my( $string, $err ) = @_;

  if( $string =~ /^\d+$/ )
  {
    if( $string < MAX_CLIENTS )
    {
      return $connectedUsers[ $string ]
        if( $connectedUsers[ $string ]{ 'connected' } != CON_DISCONNECTED );
      $$err = "no player connected in slot $string";
    }

    return $admins[ $string - MAX_CLIENTS ]
      if( $string - MAX_CLIENTS < @admins );

    $$err = "$string not in range 1-" . ( $#admins + MAX_CLIENTS );
    return;
  }

  $string = cleanstring( $string );
  my( $cmp, $match );
  foreach my $user ( @admins, @connectedUsers )
  {
    $cmp = cleanstring( $user->{ 'name' } );
    # names should be unique, so return on exact match
    return $user if( $string eq $cmp );
    if( index( $cmp, $string ) > -1 )
    {
      if( $match )
      {
        $$err = "more than one match.  use the listplayers or listadmins to " .
          "find an appropriate number to use instead of name.";
        return;
      }
      $match = $user;
    }
  }
  $$err = "no match.  use listplayers or listadmins to " .
    "find an appropriate number to use instead of name." unless( $match );
  return $match;
}

sub getuser
{
  my ( $string ) = @_;
  my $guid = lc( $string );
  foreach my $user ( @connectedUsers )
  {
    next if( $user->{ 'connected' } == CON_DISCONNECTED );
    return $user if( lc( $user->{ 'GUID' } ) eq $guid );
  }
  return;
}

sub slotFromString
{
  my ( $string, $requireConnected, $err ) = @_;
  $string = lc( $string );

  if( $string =~ /^[\d]+/ )
  {
    if( $string >= MAX_CLIENTS )
    {
      $$err = "Invalid slot #${string}";
      return( -1 );
    }

    if( $requireConnected && $connectedUsers[ $string ]{ 'connected' } != CON_CONNECTED )
    {
      $$err = "Slot #${string} is not connected";
      return( -1 );
    }
    return $string;
  }

  my $exact = -1;
  my @matches;
  for( my $i = 0; $i < MAX_CLIENTS; $i++ )
  {
    my $uname = lc( $connectedUsers[ $i ]{ 'name' } );
    next if( !$uname );

    next if( $requireConnected && $connectedUsers[ $i ]{ 'connected' } != CON_CONNECTED );

    $exact = $i if( $uname eq $string );

    push( @matches, $i ) if( index( $uname, $string ) > -1 );
  }

  my $n = scalar @matches;
  if( $exact >= 0 )
  {
    return $exact;
  }
  elsif( $n == 1 )
  {
    return $matches[ 0 ];
  }
  elsif( $n > 0 )
  {
    $$err = "Multiple name matches. Be more specific or use a slot number";
    return( -1 );
  }
  else
  {
    $$err = "No current players match string: ${string}^7";
    return( -1 );
  }
}

sub userIDFromGUID
{
  my ( $guid ) = @_;
  my $guidq = $db->quote( $guid );
  my $usersq = $db->prepare( "SELECT userID FROM users WHERE GUID = ${guidq} LIMIT 1" );
  $usersq->execute;

  my $user;

  if( $user = $usersq->fetchrow_hashref( ) )
  {
    return $user->{'userID'};
  }
  else
  {
    return "-1";
  }
}

sub timestamp
{
  if( $backlog )
  {
    my $out = $servertsstr;
    $out =~ tr{/}{-};
    return( $db->quote( $out ) );
  }
  my $q = $db->prepare( "SELECT DATETIME('now','localtime')" );
  $q->execute;
  my $out = $q->fetchrow_array( );

  $out = $db->quote( $out );
  return $out;
}

sub errorHandler
{
  # don't croak because of an error in a command handler or failed eval
  die( @_ ) if( $^S || !defined( $^S ) );
  print "Error: $_[ 0 ]";
  cleanup( );
}

sub cleanup
{
  close( FILE );
  close( SENDPIPE ) if( $sendMethod == SEND_PIPE );
  $db->disconnect( ) or warn( "Disconnection failed: $DBI::errstr\n" );
}


####
package CommandQueue;
use common::sense;
use Data::Dumper;
use Carp;
use Time::HiRes 'time';

sub new
{
  my( $package, %options ) = @_;
  return bless( {
    'time' => 0,
    'period' => 0.05,
    'queue' => [],
    'maxlength' => 1023,
    'count' => 0,
    'bucketmax' => 10,
    'bucketrate' => 1000,
    %options
  }, $package );
}

sub get
{
  my( $cq, $key ) = @_;
  return $cq->{ ${key} };
}

sub set
{
  my( $cq, $key, $value ) = @_;
  my $current = $cq->{ $key };
  $cq->{ $key } = $value if( @_ == 3 );
  return $current;
}

sub send
{
  my( $cq ) = @_;
  return unless( @{ $cq->{ 'queue' } } );
  my $t = time;

  $cq->{ 'count' } -= int( ( $t * 1000 - $cq->{ 'time' } * 1000 ) /
    $cq->{ 'bucketrate' } );
  $cq->{ 'count' } = 0 if( $cq->{ 'count' } < 0 );

  my $command;
  my $i = 0;
  my $r = $cq->{ 'maxlength' };
  for( ; $i < @{ $cq->{ 'queue' } }; $i++ )
  {
    $r -= length( $cq->{ 'queue' }[ $i ][ 1 ] ) + ( $i > 0 );
    last if( $r < -1 );
  }
  $command = join( ';', map { $$_[ 1 ] } splice( @{ $cq->{ 'queue' } }, 0, $i ) );
  if( $i == 0 )
  {
    print "Sent $i commands in ", length( $command ), " characters\n";
  }
  else
  {
    print "Sent: $command\n";
  }
  $cq->{ 'method' }( $command );
  $cq->{ 'count' }++;

  $cq->{ 'time' } = $t if( $command );
}

sub enqueue
{
  my( $cq, $command, $priority ) = @_;
  if( length( $command ) > $cq->{ 'maxlength' } )
  {
    Carp::carp( "Command too large (>$cq->{ 'maxlength' }): $command" );
  }
  else
  {
    @{ $cq->{ 'queue' } } = sort
    {
      $$a[ 0 ] <=> $$b[ 0 ]
    }
    @{ $cq->{ 'queue' } }, [ $priority, $command ];
  }
}
