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

use strict;
use warnings;
use DBI;
use Data::Dumper;
use Geo::IP::PurePerl;
use Text::ParseWords;
use Socket;
use enum;
use FileHandle;
use File::ReadBackwards;
use Fcntl ':seek';

use enum qw( CON_DISCONNECTED CON_CONNECTING CON_CONNECTED );
use enum qw( SEND_DISABLE SEND_PIPE SEND_RCON SEND_SCREEN );
use enum qw( DEM_KICK DEM_BAN DEM_MUTE DEM_DENYBUILD );

# config: best to leave these defaults alone and set each var you want to override from default in config.cfg
#         e.g. if you want to change $logpath, put a line that says
#              $logpath = "/somewherelse/games.log";
#              in config.cfg

# Path to games.log
our $logpath = "games.log";

# Where do we store the database
our $dbfile = "bot.db";

# Where do we store the geoIP database
our $gipdb = "/usr/local/share/GeoIP/GeoLiteCity.dat";

# Are we reading from the whole logfile to populate the db? Generally this is 0
our $backlog = 0;

# How should we send output responses back to the server?
#  SEND_DISABLE: Do not send output responses back to the server.
#  SEND_PIPE:    Write to a pipefile, as configured by the com_pipefile option. Best option if available.
#                Fast and robust.
#  SEND_RCON:    Use rcon. Requires netcat, ideally a freeBSD netcat.
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

# name of screen session, only used for SEND_SCREEN
our $screenName = "tremded";

do 'config.cfg';
# ------------ CONFIG STUFF ENDS HERE. DON'T MODIFY AFTER THIS OR ELSE!! ----------------


$SIG{INT} = \&cleanup;
$SIG{__DIE__} = \&errorHandler;

print( "TremAdminBot: A bot that provides some helper functions for Tremulous server administration\n" );
print( "TremAdminBot Copyright (C) 2011 Christopher Schwarz (lakitu7\@mercenariesguild.net)\n" );
print( "This program comes with ABSOLUTELY NO WARRANTY.\n" );
print( "This is free software, and you are welcome to redistribute it under certain conditions.\n" );
print( "For details, see gpl.txt\n" );
print( "-------------------------------------------------------------------------------------------\n" );

my $gi = Geo::IP::PurePerl->open( $gipdb, GEOIP_STANDARD );
my $db = DBI->connect( "dbi:SQLite:${dbfile}", "", "", { RaiseError => 1, AutoCommit => 0 } ) or die( "Database error: " . $DBI::errstr );

# uncomment to dump all db activity to stdout
#`$db->{TraceLevel} = 1;

# create tables if they do not exist already
{
  my @tables;

  @tables = $db->tables( undef, undef, "users", undef );
  if( !scalar @tables )
  {
    $db->do( "CREATE TABLE users( userID INTEGER PRIMARY KEY, name TEXT, GUID TEXT, useCount INTEGER, seenTime DATETIME, IP TEXT, adminLevel INTEGER, city TEXT, region TEXT, country TEXT )" );
    $db->do( "CREATE INDEX guidIndex on users( GUID )" );
    $db->do( "INSERT INTO users ( name, GUID, useCount, adminLevel ) VALUES ( \'console\', \'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX\', 0, 999 )" );
  }

  @tables = $db->tables( undef, undef, "names", undef );
  if( !scalar @tables )
  {
    $db->do( "CREATE TABLE names( nameID INTEGER PRIMARY KEY, name TEXT, nameColored TEXT, userID INTEGER, useCount INTEGER, seenTime DATETIME, FOREIGN KEY( userID ) REFERENCES users( userID ) )" );
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

# allocate
my @connectedUsers;
for( my $i = 0; $i < 64; $i++ )
{
  push( @connectedUsers, { 'connected' => CON_DISCONNECTED } );
}
my $linesProcessed = -1;

my $servertsstr = "";
my $servertsminoff;
my $servertssecoff;

my $lineRegExp = qr/^([\d ]{3}):([\d]{2}) ([\w]+): (.*)/;
my $clientConnectRegExp = qr/^([\d]+) \[(.*)\] \(([\w]+)\) \"(.*)\" \"(.*)\"/;
my $clientDisconnectRegExp = qr/^([\d]+)/;
my $clientBeginRegExp = qr/^([\d-]+)/;
my $adminAuthRegExp = qr/^([\d-]+) \"(.+)\" \"(.+)\" \[([\d]+)\] \(([\w]+)\):/;
my $clientRenameRegExp = qr/^([\d]+) \[(.*)\] \(([\w]+)\) \"(.*)\" -> \"(.*)\" \"(.*)\"/;
my $sayRegExp = qr/^([\d-]+) \"(.+)\": (.*)/;
my $adminExecRegExp = qr/^([\w]+): ([\d-]+) \"(.*)\" \"(.*)\" \[([\d]+)\] \(([\w]*)\): ([\w]+):?/;
my $nameRegExpUnquoted= qr/.+/;
my $nameRegExpQuoted = qr/\".+\"/;
my $nameRegExp = qr/${nameRegExpQuoted}|${nameRegExpUnquoted}/o;

my $startupBacklog = 0;

my %cmds;
sub loadcmds
{
  my $sub;
  %cmds = ();
  return unless( opendir( CMD, 'cmds' ) );
  foreach my $cmd( readdir( CMD ) )
  {
    next unless( substr( $cmd, -4 ) eq 'cmd' );
    $sub = do( $cmd );
    unless( $sub )
    {
      warn( "$cmd: $@\n" );
      next;
    }
    $cmds{ $cmd } = $sub;
  }
  closedir( CMD );
}
$SIG{ 'HUP' } = \&loadcmds;
loadcmds;

open( FILE, "<",  $logpath ) or die( "open logfile failed: ${logpath}" );
if( !$backlog && $sendMethod == SEND_PIPE )
{
  die( "${pipefilePath} is not a pipe. Is tremded running?" )
    if( !-p( $pipefilePath ) );
  open( SENDPIPE, ">", $pipefilePath );
  SENDPIPE->autoflush( 1 );
}

if( !$backlog ) # Seek back to the start of the current game game
{
  my $bw = File::ReadBackwards->new( $logpath );
  my $seekPos = 0;
  $startupBacklog = 1;

  while( defined( my $line = $bw->readline( ) ) )
  {
    if( $line =~ $lineRegExp )
    {
      my $arg0 = $3;
      if( $arg0 eq "InitGame" )
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
else
{
  print( "Processing backlog on file ${logpath}. This will take a long time for large files.\n" );
}

while( 1 )
{
  if( my $line = <FILE> )
  {
    chomp $line;
    #`print "${line}\n";

    my $timestamp = timestamp( );

    $linesProcessed++;

    # Committing periodically instead of using autocommit speeds the db up massively
    if( $linesProcessed % 100 )
    {
      $db->commit( );
    }

    if( $backlog && $linesProcessed % 1000 )
    {
      print( "Processed ${linesProcessed} lines. Current timestamp: ${timestamp}\r" );
    }

    if( ( $servertsminoff, $servertssecoff, my $arg0, my $args ) = $line =~ $lineRegExp )
    {
      if( $arg0 eq "ClientConnect" )
      {
        unless( @_ = $args =~ $clientConnectRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $slot, $ip, $guid, $name, $nameColored ) = @_;

        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTING;
        $connectedUsers[ $slot ]{ 'name' } = $name;
        $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;
        $connectedUsers[ $slot ]{ 'IP' } = $ip;
        $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        $connectedUsers[ $slot ]{ 'aname' } = "";
        $connectedUsers[ $slot ]{ 'alevel' } = "";

        $connectedUsers[ $slot ]{ 'IP' } ||= "127.0.0.1";

        updateUsers( $timestamp, $slot );

      }
      elsif( $arg0 eq "ClientDisconnect" )
      {
        unless( $args =~ $clientDisconnectRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my $slot = $1;
        $connectedUsers[ $slot ]{ 'connected' } = CON_DISCONNECTED;
      }
      elsif( $arg0 eq "ClientBegin" )
      {
        unless( $args =~ $clientBeginRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my $slot = $1;
        my $name = $connectedUsers[ $slot ]{ 'name' };
        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTED;

        $connectedUsers[ $slot ]{ 'alevel' } ||= 0;

        next if( $startupBacklog );

        memocheck( $slot, $timestamp );

      }
      elsif( $arg0 eq "AdminAuth" )
      {
        unless( @_ = $args =~ $adminAuthRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $slot, $name, $aname, $alevel, $guid ) = @_;

        $connectedUsers[ $slot ]{ 'aname' } = $aname;
        $connectedUsers[ $slot ]{ 'alevel' } = $alevel;
        $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        my $userID = $connectedUsers[ $slot ]{ 'userID' };

        my $anameq = $db->quote( $aname );

        $db->do( "UPDATE users SET name=${anameq}, adminLevel=$alevel WHERE userID=${userID}" );
      }
      elsif( $arg0 eq "ClientRename" )
      {
        unless( @_ = $args =~ $clientRenameRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $slot, $ip, $guid, $previousName, $name, $nameColored ) = @_;
        $connectedUsers[ $slot ]{ 'previousName' } = $previousName;
        $connectedUsers[ $slot ]{ 'name' } = $name;
        $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;

        updateNames( $timestamp, $slot );
      }
      elsif( $arg0 eq "RealTime" )
      {
        $servertsstr = $args;
      }

      # Commands after this point are not interacted with in startupBacklog conditions
      next if( $startupBacklog );

      if( $arg0 eq "AdminExec" )
      {
        unless( @_ = $args =~ $adminExecRegExp )
        {
          print( "Parse failure on ${arg0} ${args}\n" );
          next;
        }
        my( $status, $slot, $name, $aname, $alevel, $guid, $acmd ) = @_;
        my @toks = quotewords( '\s+', 1, $args );
        @toks = grep( defined $_, @toks);
        my $acmdargs = "";
        $acmdargs = join( " ", @toks[ 7 .. $#toks ] ) if( scalar @toks >= 7 );

        my $nameq = $db->quote( $name );
        $acmd = lc( $acmd );

        my $userID = $connectedUsers[ $slot ]{ 'userID' };
        if( $slot == -1 )
        {
          $userID = 1; # console is always userID 1
          $guid = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
        }

        #`print "admin command: status: ${status} slot ${slot} name ${name} aname ${aname} acmd ${acmd} acmdargs ${acmdargs}\n";
        next if( "${status}" ne "ok" );

        next if( $backlog && ( exists( $cmds{ $acmd } ) || $acmd eq "seen" || $acmd eq "memo" || $acmd eq "geoip" || $acmd eq "l1" || 
                 $acmd eq "aliases" || $acmd eq "rapsheet" ) );

        if( exists( $cmds{ $acmd } ) )
        {
          my %admin =
          (
            slot => $slot,
            name => $name,
            aname => $aname,
            alevel => $alevel,
            guid => $guid
          );
          $cmds{ $acmd }( \%admin, $acmdargs, $db );
        }
        elsif( $acmd eq "seen" )
        {
          my $seenstring = $acmdargs;
          print( "Cmd: ${name} /seen ${seenstring}\n" );

          if( $acmdargs eq "" )
          {
            replyToPlayer( $slot, "^3seen:^7 usage: seen <name>" );
            next;
          }

          $seenstring = lc( $seenstring );
          my $seenstringq = $db->quote( $seenstring );
          my $seenstringlq = $db->quote( "\%" . $seenstring . "\%" );
          my $q = $db->prepare( "SELECT name, seenTime, useCount FROM names WHERE name like ${seenstringlq} ORDER BY CASE WHEN name = ${seenstringq} THEN 999999 else useCount END DESC LIMIT 4" );
          $q->execute;

          my $rescount = 0;
          while( my $ref = $q->fetchrow_hashref( ) )
          {
            my $seenname = $ref->{'name'};
            my $seentime = $ref->{'seenTime'};
            my $seencount = $ref->{'useCount'};
            replyToPlayer( $slot, "^3seen:^7 Player ${seenname} seen ${seencount} times, last: ${seentime}" );
            ++$rescount;
            last if( $rescount > 2 );
          }

          my $ref = $q->fetchrow_hashref( );
          if( $rescount > 0 && $ref )
          {
            replyToPlayer( $slot, "^3seen:^7 Too many results to display. Try a more specific query." );
          }
          elsif( $rescount == 0 )
          {
            replyToPlayer( $slot, "^3seen:^7 Player ${seenstring} not found" );
          }
        }
        elsif( $acmd eq "memo" )
        {
          unless( $acmdargs =~ /^([\w]+)/ )
          {
            replyToPlayer( $slot, "^3memo:^7 commands: list, read, send, outbox, unsend, clear" );
            next;
          }

          my $memocmd = lc( $1 );
          print( "Cmd: ${name} /memo ${acmdargs}\n" );

          if( $memocmd eq "send" )
          {
            my @split = shellwords( $acmdargs );
            shift( @split );
            unless( scalar @split >= 2 )
            {
              replyToPlayer( $slot, "^3memo:^7 usage: memo send <name> <message>" );
              next;
            }

            my $memoname = lc( shift( @split ) );
            my $memo = join( " ", @split );
            my $memoq = $db->quote( $memo );

            $memoname =~ tr/\"//d;
            my $memonameq = $db->quote( $memoname );
            my $memonamelq = $db->quote( "\%" . $memoname . "\%" );

            my $q = $db->prepare( "SELECT users.userID, users.name FROM users WHERE users.useCount > 10 AND users.name LIKE ${memonamelq} AND users.seenTime > datetime( ${timestamp}, \'-3 months\') ORDER BY CASE WHEN users.name = ${memonameq} then 999999 else users.useCount END DESC LIMIT 10" );
            $q->execute;

            my @matches;
            my $lastmatch;
            my $exact = -1;
            my $i = 0;
            while( my $ref = $q->fetchrow_hashref( ) )
            {
              $exact = $i if( $ref->{ 'name' } eq $memoname );
              $lastmatch = $ref->{ 'userID' };
              push( @matches, $ref->{ 'name' } );
              last if( $exact >= 0 );
              $i++;
            }

            if( $exact >= 0 )
            {
              my $memonameq = $db->quote( $memoname );
              $db->do( "INSERT INTO memos (userID, sentBy, sentTime, msg) VALUES (${lastmatch}, ${userID}, ${timestamp}, ${memoq})" );
              replyToPlayer( $slot, "^3memo:^7 memo left for ${matches[ $exact ]}" );
            }
            elsif( scalar @matches == 1 )
            {
              my $memonameq = $db->quote( $lastmatch );
              $db->do( "INSERT INTO memos (userID, sentBy, sentTime, msg) VALUES (${lastmatch}, ${userID}, ${timestamp}, ${memoq})" );
              replyToPlayer( $slot, "^3memo:^7 memo left for ${matches[ 0 ]}" );
            }
            elsif( scalar @matches > 1 )
            {
              replyToPlayer( $slot, "^3memo:^7 multiple matches. Be more specific: " . join( "^3,^7 ", @matches ) );
            }
            else
            {
              replyToPlayer( $slot, "^3memo:^7 invalid memo target: ${memoname} not seen in last 3 months or at least 10 times." );
            }
          }
          elsif( $memocmd eq "list" )
          {
            my $q = $db->prepare( "SELECT memos.memoID, memos.readTime, users.name FROM memos JOIN users ON users.userID = memos.sentBy WHERE memos.userID = ${userID} ORDER BY memoID ASC" );
            $q->execute;

            my @memos;
            my @readMemos;
            while( my $ref = $q->fetchrow_hashref( ) )
            {
              my $name = $ref->{ 'name' };
              my $readTime = $ref->{ 'readTime' };
              my $memoID = $ref->{ 'memoID' };

              if( $readTime )
              {
                push( @readMemos, ${memoID} );
              }
              else
              {
                push( @memos, ${memoID} );
              }
            }
            my $newCount = scalar @memos;
            my $readCount = scalar @readMemos;
            replyToPlayer( $slot, "^3memo:^7 You have ${newCount} new Memos: " . join( "^3,^7 ", @memos ) . ". Use /memo read <memoID>" ) if( $newCount );
            replyToPlayer( $slot, "^3memo:^7 You have ${readCount} read Memos: " . join( "^3,^7 ", @readMemos ) ) if( $readCount );
            replyToPlayer( $slot, "^3memo:^7 You have no memos." ) if( !$newCount && !$readCount );
          }

          elsif( $memocmd eq "read" )
          {
            my $memoID;
            unless( ( $memoID ) = $acmdargs =~ /^(?:[\w]+) ([\d]+)/ )
            {
              replyToPlayer( $slot, "^3memo:^7 usage: memo read <memoID>" );
              next;
            }
            my $memoIDq = $db->quote( $memoID );

            my $q = $db->prepare( "SELECT memos.memoID, memos.sentTime, memos.msg, users.name FROM memos JOIN users ON users.userID = memos.sentBy WHERE memos.memoID = ${memoIDq} AND memos.userID = ${userID}" );
            $q->execute;
            if( my $ref = $q->fetchrow_hashref( ) )
            {
              my $id = $ref->{ 'memoID' };
              my $from = $ref->{ 'name' };
              my $sentTime = $ref->{ 'sentTime' };
              my $msg = $ref->{ 'msg' };

              replyToPlayer( $slot, "Memo: ${id} From: ${from} Sent: ${sentTime}" );
              replyToPlayer( $slot, " Msg: ${msg}" );

              $db->do( "UPDATE memos SET readTime=${timestamp} WHERE memoID=${memoIDq}" );
            }
            else
            {
              replyToPlayer( $slot, "^3memo:^7: Invalid memoID: ${memoID}" );
            }
          }
          elsif( $memocmd eq "outbox" )
          {
            my $q = $db->prepare( "SELECT memos.memoID, users.name FROM memos JOIN users ON users.userID = memos.userID WHERE memos.sentBy = ${userID} AND memos.readTime IS NULL ORDER BY memoID ASC" );
            $q->execute;

            my @memos;
            while( my $ref = $q->fetchrow_hashref( ) )
            {
              my $name = $ref->{ 'name' };
              my $memoID = $ref->{ 'memoID' };

              push( @memos, "ID: ${memoID} To: ${name}" );
            }
            replyToPlayer( $slot, "^3memo:^7 Unread Sent Memos: " . join( "^3,^7 ", @memos ) ) if( scalar @memos );
            replyToPlayer( $slot, "^3memo:^7 You have no unread sent memos." ) if( ! scalar @memos );
          }
          elsif( $memocmd eq "unsend" )
          {
            my $memoID;
            unless( ( $memoID ) = $acmdargs =~ /^(?:[\w]+) ([\d]+)/ )
            {
              replyToPlayer( $slot, "^3memo:^7 usage: memo unsend <memoID>" );
              next;
            }

            my $memoIDq = $db->quote( $memoID );

            my $count = $db->do( "DELETE FROM memos WHERE sentBy = ${userID} AND memoID = ${memoIDq}" );
            if( $count ne "0E0" )
            {
              replyToPlayer( $slot, "^3memo:^7 deleted sent memo ${memoID}" );
            }
            else
            {
              replyToPlayer( $slot, "^3memo:^7 invalid memoID ${memoID}" );
            }
          }
          elsif( $memocmd eq "clear" )
          {
            my $clearcmd;
            unless( ( $clearcmd ) = $acmdargs =~ /^(?:[\w]+) ([\w]+)/ )
            {
              replyToPlayer( $slot, "^3memo:^7 usage: memo clear <ALL|READ>" );
              next;
            }
            $clearcmd = lc( $clearcmd );

            if( $clearcmd eq "all" )
            {
              my $count = $db->do( "DELETE FROM memos WHERE userID = ${userID}" );
              $count = 0 if( $count eq "0E0" );
              replyToPlayer( $slot, "^3memo:^7 cleared ${count} memos" );
            }
            elsif( $clearcmd eq "read" )
            {
              my $count = $db->do( "DELETE FROM memos WHERE userID = ${userID} AND readTime IS NOT NULL" );
              $count = 0 if( $count eq "0E0" );
              replyToPlayer( $slot, "^3memo:^7 cleared ${count} read memos" );
            }
            else
            {
              replyToPlayer( $slot, "^3memo:^7 usage: memo clear <ALL|READ>" );
            }
          }
          else
          {
            replyToPlayer( $slot, "^3memo:^7 commands: list, read, send, outbox, unsend, clear" );
          }
        }
        elsif( $acmd eq "geoip" )
        {
          my $gipip;
          my $gipname;
          print( "Cmd: ${name} /geoip ${acmdargs}\n" );

          if( $acmdargs =~ /^([\d]+\.[\d]+\.[\d]+\.[\d]+)/ )
          {
            $gipip = $gipname = $1;
          }
          elsif( $acmdargs =~ /^($nameRegExp)/ )
          {
            my $giptarg = $1;
            my $err = "";
            my $gipslot = slotFromString( $giptarg, 0, \$err );
            if( $gipslot < 0 )
            {
              replyToPlayer( $slot, "^3geoip:^7 ${err}" );
              next;
            }

            if( $connectedUsers[ $gipslot ]{ 'IP' } )
            {
              $gipip = $connectedUsers[ $gipslot ]{ 'IP' };
              $gipname = $connectedUsers[ $gipslot ]{ 'name' };
            }
            else
            {
              replyToPlayer( $slot, "^3geoip:^7 Unused slot #${giptarg}" );
              next;
            }
          }
          else
          {
            replyToPlayer( $slot, "^3geoip:^7 usage: geoip <name|slot#|IP>" );
            next;
          }
          my $gipinfo = $gi->get_city_record_as_hash( $gipip );
          my $gipcountry = $$gipinfo{ 'country_name' };
          my $gipcity = $$gipinfo{ 'city' };
          my $gipregion = $$gipinfo{ 'region' };
          my $gipiaddr = inet_aton( $gipip );
          my $giphostname = gethostbyaddr( $gipiaddr, AF_INET );
          $giphostname ||= "";
          $gipcountry ||= "";
          $gipcity ||= "";
          $gipregion ||= "";
          replyToPlayer( $slot, "^3geoip:^7 ${gipname} connecting from ${giphostname} ${gipcity} ${gipregion} ${gipcountry}" );
        }
        elsif( $acmd eq "l1" )
        {
          print( "Cmd: ${name} /l1 ${acmdargs}\n" );

          if( $acmdargs eq "" )
          {
            replyToPlayer( $slot, "^3l1:^7 usage: l1 <name|slot#>" );
            next;
          }

          my $err = "";
          my $targslot = slotFromString( $acmdargs, 1, \$err );
          if( $targslot < 0 )
          {
            replyToPlayer( $slot, "^3l1:^7 ${err}" );
            next;
          }

          if( $connectedUsers[ $targslot ]{ 'alevel' } == 0 )
          {
            printToPlayers( "^3l1:^7 ${name} set ${connectedUsers[ $targslot ]{ 'name' }} to level 1" );
            sendconsole( "setlevel ${targslot} 1" );
          }
          else
          {
            replyToPlayer( $slot, "^3l1:^7 User #${targslot} is not level 0" );
            next;
          }
        }
        elsif( $acmd eq "aliases" )
        {
          print( "Cmd: ${name} /aliases ${acmdargs}\n" );

          if( $acmdargs eq "" )
          {
            replyToPlayer( $slot, "^3aliases:^7 usage: aliases <name|slot#>" );
            next;
          }

          my $err = "";
          my $targslot = slotFromString( $acmdargs, 1, \$err );
          if( $targslot < 0 )
          {
            replyToPlayer( $slot, "^3aliases:^7 ${err}" );
            next;
          }

          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $namesq = $db->prepare( "SELECT nameColored FROM names WHERE userID = ${targUserID} ORDER BY useCount DESC LIMIT 15" );
          $namesq->execute;

          my @aliases;
          while( my $ref = $namesq->fetchrow_hashref( ) )
          {
            push( @aliases, $ref->{ 'nameColored' } );
          }
          push( @aliases, $connectedUsers[ $targslot ]{ 'nameColored' } ) if( !scalar @aliases );
          my $count = scalar @aliases;

          replyToPlayer( $slot, "^3aliases:^7 ${count} names found: " . join( "^3,^7 ", @aliases ) ) if( $count );
        }
        elsif( $acmd eq "rapsheet" )
        {
          print( "Cmd: ${name} /rapsheet ${acmdargs}\n" );

          my( $targ, $param ) = shellwords( $acmdargs );
          if( $targ eq "" )
          {
            replyToPlayer( $slot, "^3rapsheet:^7 usage: rapsheet <name|slot#> [GUID|IP|SUBNET]" );
            next;
          }

          my $err = "";
          my $targslot = slotFromString( $targ, 1, \$err );
          if( $targslot < 0 )
          {
            replyToPlayer( $slot, "^3rapsheet:^7 ${err}" );
            next;
          }

          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targName = $connectedUsers[ $targslot ]{ 'nameColored' };
          my $targIP = $connectedUsers[ $targslot ]{ 'IP' };

          my $searchtype;
          my $query;
          if( lc( $param ) eq "ip" )
          {
            $searchtype = "IP";
            my $targIPq = $db->quote( $targIP );
            $query = "SELECT demeritType FROM demerits WHERE IP = ${targIPq}";
          }
          elsif( lc( $param ) eq "subnet" )
          {
            $searchtype = "SUBNET";
            if( my( $ip1, $ip2, $ip3, $ip4 ) = $targIP =~ /([\d]+)\.([\d]+)\.([\d]+)\.([\d]+)/ )
            {
              my $targSubq = $db->quote( "${ip1}.${ip2}.${ip3}.\%" );
              $query = "SELECT demeritType FROM demerits WHERE IP LIKE ${targSubq}";
            }
            else
            {
              replyToPlayer( $slot, "^3rapsheet:^7 player is not connected via ipv4." );
              next;
            }
          }
          else
          {
            $searchtype = "GUID";
            $query = "SELECT demeritType FROM demerits WHERE userID = ${targUserID}";
          }

          my $kicks = 0;
          my $bans = 0;
          my $mutes = 0;
          my $denybuilds = 0;

          my $demq = $db->prepare( $query );
          $demq->execute;

          while( my $dem = $demq->fetchrow_hashref( ) )
          {
            if( $dem->{ 'demeritType' } == DEM_KICK )
            {
              $kicks++;
            }
            elsif( $dem->{ 'demeritType' } == DEM_BAN )
            {
              $bans++;
            }
            elsif( $dem->{ 'demeritType' } == DEM_MUTE )
            {
              $mutes++;
            }
            elsif( $dem->{ 'demeritType' } == DEM_DENYBUILD )
            {
              $denybuilds++;
            }
          }

          replyToPlayer( $slot, "^3rapsheet:^7 ${targName}^7 offenses by ${searchtype}: Kicks: ${kicks} Bans: ${bans} Mutes: ${mutes} Denybuilds: ${denybuilds}" );
        }
        # --------- Stuff that we don't respond to, but track ---------
        elsif( $acmd eq "kick" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted): \"(.*)\"/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $targslot, $targGUID, $targName, $reason ) = @_;
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          my $reasonq = $db->quote( $reason );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip, reason) VALUES ( ${targUserID}, " . DEM_KICK . ", ${userID}, ${timestamp}, ${targIPq}, ${reasonq} )" );
        }
        elsif( $acmd eq "ban" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted): \"(.*)\": \[(.*)\]/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $duration, $targGUID, $targName, $reason, $targIP ) = @_;

          my $targUserID = userIDFromGUID( $targGUID );
          if( $targUserID == -1 )
          {
            print( "Error: ban on unknown guid ${targGUID}\n" );
            next;
          }

          my $targIPq = $db->quote( $targIP );
          my $reasonq = $db->quote( $reason );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip, reason, duration) VALUES ( ${targUserID}, " . DEM_BAN . ", ${userID}, ${timestamp}, ${targIPq}, ${reasonq}, $duration )" );
        }
        elsif( $acmd eq "mute" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted)/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $targslot, $targGUID, $targName ) = @_;
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip) VALUES ( ${targUserID}, " . DEM_MUTE . ", ${userID}, ${timestamp}, ${targIPq} )" );
        }
        elsif( $acmd eq "denybuild" )
        {
          unless( @_ = $acmdargs =~ /^([\d]+) \(([\w]+)\) ($nameRegExpQuoted)/ )
          {
            print( "Parse failure on AdminExec ${acmdargs}\n" );
            next;
          }
          my( $targslot, $targGUID, $targName ) = @_;
          my $targUserID = $connectedUsers[ $targslot ]{ 'userID' };
          my $targIPq = $db->quote( $connectedUsers[ $targslot ]{ 'IP' } );
          $db->do( "INSERT INTO demerits (userID, demeritType, admin, timeStamp, ip) VALUES ( ${targUserID}, " . DEM_DENYBUILD . ", ${userID}, ${timestamp}, ${targIPq} )" );
        }
      }
      # Unused at present but left here for if other people want to screw with it
      #`elsif( $arg0 eq "Say" || $arg0 eq "SayTeam" || $arg0 eq "AdminMsg" )
      #`{
        #`$args =~ $sayRegExp;
        #`my $slot = $1;
        #`my $player = $2;
        #`my $said = $3;
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
      print( "Finished startup routines. Watching logfile:\n" );
    }

    seek( FILE, 0, SEEK_CUR );
    sleep 1;
  }
}

sub replyToPlayer
{
  my( $slot, $string ) = @_;

  if( $slot > 0 )
  {
    sendconsole( "pr ${slot} ${string}" );
  }
  else
  {
    sendconsole( "echo ${string}" );
  }
}

sub printToPlayers
{
  my( $string ) = @_;
  sendconsole( "pr -1 ${string}" );
}

sub sendconsole
{
  my( $string ) = @_;
  return if( $backlog || $startupBacklog || $sendMethod == SEND_DISABLE );

  $string =~ tr/'//d;
  $string = substr( $string, 0, 1024 );
  my $outstring = "";

  if( $sendMethod == SEND_PIPE )
  {
    print( SENDPIPE "${string}\n" ) or die( "Broken pipe!" );
  }
  elsif( $sendMethod == SEND_RCON )
  {
    $outstring = `echo -e \'\xff\xff\xff\xffrcon ${rcpass} ${string}\' | nc -w 0 -u ${ip} ${port}`;
  }
  elsif( $sendMethod == SEND_SCREEN )
  {
    `screen -S ${screenName} -p 0 -X stuff $\'\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10${string}\n\'`
  }
  else
  {
    die "Invalid $sendMethod configured";
  }

  if( $outstring )
  {
    #print "Output: $outstring";
  }
  print "Sent: ${string}\n";
  return $outstring;
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

  my $usersq = $db->prepare( "SELECT userID, adminLevel FROM users WHERE GUID = ${guidq} LIMIT 1" );
  $usersq->execute;

  my $user;

  if( $user = $usersq->fetchrow_hashref( ) )
  { }
  else
  {
    my $gip = $gi->get_city_record_as_hash( $ip );
    my $city = $db->quote( $$gip{ 'city' } );
    my $region = $db->quote( $$gip{ 'region' } );
    my $country = $db->quote( $$gip{ 'country_name' } );

    $db->do( "INSERT INTO users ( name, GUID, useCount, seenTime, IP, adminLevel, city, region, country ) VALUES ( ${nameq}, ${guidq}, 0, ${timestamp}, ${ipq}, 0, ${city}, ${region}, ${country} )" );
    $usersq->execute;
    $user = $usersq->fetchrow_hashref( );
  }

  my $userID = $user->{ 'userID' };
  my $adminLevel = $user->{ 'adminLevel' };
  $connectedUsers[ $slot ]{ 'userID' } = $userID;

  return if( $startupBacklog );

  updateNames( $timestamp, $slot );

  if( !$adminLevel )
  {
    my $namesq = $db->prepare( "SELECT name FROM names WHERE userID = $userID ORDER BY useCount DESC LIMIT 1" );
    $namesq->execute;
    if( my $maxname = $namesq->fetchrow_hashref( ) )
    {
      my $maxnameq = $db->quote( $maxname->{ 'name' } );
      $db->do( "UPDATE users SET name=${maxnameq}, useCount=useCount+1, seenTime=${timestamp}, ip=${ipq} WHERE userID=${userID}" );
    }
    else
    {
      $db->do( "UPDATE users SET name=${nameq}, useCount=useCount+1, seenTime=${timestamp}, ip=${ipq} WHERE userID=${userID}" );
    }
  }
  else
  {
    $db->do( "UPDATE users SET useCount=useCount+1, seenTime=${timestamp}, ip=${ipq} WHERE userID=${userID}" );
  }
}

sub updateNames
{
  my( $timestamp, $slot ) = @_;
  my $name = lc( $connectedUsers[ $slot ]{ 'name' } );
  my $nameq = $db->quote( $name );
  my $namec = $connectedUsers[ $slot ]{ 'nameColored' };
  my $namecq = $db->quote( $namec );
  my $userID = $connectedUsers[ $slot ]{ 'userID' };
  my $nameID = "-1";

  my $namesq = $db->prepare( "SELECT nameID FROM names WHERE name = ${nameq} LIMIT 1" );
  $namesq->execute;

  my $namesref;

  if( my $ref = $namesq->fetchrow_hashref( ) )
  {
    $nameID = $ref->{nameID};
  }
  else
  {
    $db->do( "INSERT INTO names ( name, nameColored, userID, useCount, seenTime ) VALUES ( ${nameq}, ${namecq}, ${userID}, 0, ${timestamp} )" );
    $nameID = $db->last_insert_id( undef, undef, "names", "nameID" );
  }

  return if( $startupBacklog );
  $nameID ||= "-1";

  $db->do( "UPDATE names SET usecount=useCount+1, seenTime=${timestamp}, userID=${userID} WHERE nameID = ${nameID}" );
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

  replyToPlayer( $slot, "You have ${count} new memos. Use /memo list to read." ) if( $count > 0 );

}

sub slotFromString
{
  my ( $string, $requireConnected, $err ) = @_;
  $string = lc( $string );

  if( $string =~ /^[\d]+/ )
  {
    if( $string >= 64 )
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
  for( my $i = 0; $i < 64; $i++ )
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
    $out =~ tr/\//-/;
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
  print "Error: $_[ 0 ]";
  cleanup( );
}

sub cleanup
{
  close( FILE );
  close( SENDPIPE ) if( $sendMethod == SEND_PIPE );
  $db->disconnect( ) or warn( "Disconnection failed: $DBI::errstr\n" );
  exit;
}
