use strict;
use warnings;
use DBI;
use Data::Dumper;
use Geo::IP::PurePerl;
use Socket;
use enum;

# config
our $ip;
our $port;
our $rcpass;
our $log;
our $db;
our $disablerespond;
our $backlog;
our $startupBacklogAmt;
do 'config.cfg'; 
my $gi = Geo::IP::PurePerl->open( "/usr/local/share/GeoIP/GeoLiteCity.dat", GEOIP_STANDARD );

# allocate
use enum qw( CON_DISCONNECTED CON_CONNECTING CON_CONNECTED );
my @connectedUsers;
for( my $i = 0; $i < 64; $i++ )
{
  push( @connectedUsers, {'connected' => CON_DISCONNECTED} );
}

my $servertsstr;
my $servertsminoff;
my $servertssecoff;

my $lineRegExp = qr/^([\d ]{3}):([\d]{2}) ([\w]+): (.*)/;
my $clientConnectRegExp = qr/^([\d]+) \[([0-9.]*)\] \(([\w]+)\) \"(.*)\" \"(.*)\"/;
my $clientDisconnectRegExp = qr/^([\d]+)/;
my $clientBeginRegExp = qr/^([\d-]+)/;
my $adminAuthRegExp = qr/^([\d-]+) \"(.+)\" \"(.+)\" \[([\d]+)\] \(([\w]+)\):/;
my $clientRenameRegExp = qr/^([\d]+) \[([0-9.]*)\] \(([\w]+)\) \"(.*)\" -> \"(.*)\" \"(.*)\"/;
my $sayRegExp = qr/^([\d-]+) \"(.+)\": (.*)/;
my $adminCmdRegExp = qr/^([\d-]+) \"(.*)\" \(\"(.*)\"\) \[([\d]+)\]: ([\w]+) (.*)/;

my $startupBacklog = 1;

open( FILE, "<",  $log ) or die "open failed";
if( !$backlog )
{
  seek( FILE, $startupBacklogAmt, 2 ) or die "seek fail";  # need to use 2 instead of SEEK_END. No idea why.
}
while( 1 )
{ 
  if( my $line = <FILE> ) 
  { 
    chomp $line;
    #`print "${line}\n";

    my $timestamp = timestamp( );
    
    if( $line =~ /$lineRegExp/ )
    {
      $servertsminoff = $1;
      $servertssecoff = $2;
      my $arg0 = $3;
      my $args = $4;

      #`print "arg0: ${arg0} args: ${args}\n";

      if( $arg0 eq "ClientConnect" )
      {
        if( $args =~ /$clientConnectRegExp/ )
        {
          my $slot = $1;
          my $ip = $2;
          my $guid = $3;
          my $name = $4;
          my $nameColored = $5;
          #print "slot ${slot} ip ${ip} guid ${guid} name ${name}\n";

          $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTING;
          $connectedUsers[ $slot ]{ 'name' } = $name;
          $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;
          $connectedUsers[ $slot ]{ 'IP' } = $ip;
          $connectedUsers[ $slot ]{ 'GUID' } = $guid;
          $connectedUsers[ $slot ]{ 'aname' } = "";
          $connectedUsers[ $slot ]{ 'alevel' } = "";

          next if( $startupBacklog );

          updateSeen( $name, $timestamp );
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientDisconnect" )
      {
        if( $args =~ /$clientDisconnectRegExp/ )
        {
          my $slot = $1;
          $connectedUsers[ $slot ]{ 'connected' } = CON_DISCONNECTED;
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientBegin" )
      {
        $args =~ /$clientBeginRegExp/;
        my $slot = $1;
        my $name = $connectedUsers[ $slot ]{ 'name' };
        $connectedUsers[ $slot ]{ 'connected' } = CON_CONNECTED;
        #`print( "Begin: ${name}\n" );

        $connectedUsers[ $slot ]{ 'alevel' } ||= 0;

        next if( $startupBacklog );

        memocheck( $slot );

      }
      elsif( $arg0 eq "AdminAuth" )
      {
        if( $args =~/$adminAuthRegExp/ )
        {
          my $slot = $1;
          my $name = $2;
          my $aname = $3;
          my $alevel = $4;
          my $guid = $5;

          #`print "Auth: Slot: ${slot} name: ${name} aname: ${aname} alevel: ${alevel} guid: ${guid}\n";

          $connectedUsers[ $slot ]{ 'aname' } = $aname;
          $connectedUsers[ $slot ]{ 'alevel' } = $alevel;
          $connectedUsers[ $slot ]{ 'GUID' } = $guid;
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "ClientRename" )
      {
        if( $args =~ /$clientRenameRegExp/ )
        {
          my $slot = $1;
          my $ip = $2;
          my $guid = $3;
          my $previousName = $4;
          my $name = $5;
          my $nameColored = $6;

          $connectedUsers[ $slot ]{ 'previousName' } = $previousName;
          $connectedUsers[ $slot ]{ 'name' } = $name;
          $connectedUsers[ $slot ]{ 'nameColored' } = $nameColored;

          next if( $startupBacklog );

          updateSeen( $name, $timestamp );
          memocheck( $slot );
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      elsif( $arg0 eq "RealTime" )
      {
        $servertsstr = $args;
      }

      next if( $startupBacklog );

      if( $arg0 eq "AdminCmd" )
      {
        if( $args =~ /$adminCmdRegExp/ )
        {
          my $slot = $1;
          my $name = $2;
          my $nameq = $db->quote( $name );
          my $aname = $3;
          my $alevel = $4;
          my $acmd = $5;
          $acmd = lc($acmd);
          my $acmdargs = $6;
          my $guid;

          if( $slot != -1 )
          {
            $guid = $connectedUsers[ $slot ]{ 'GUID' };
          }
          else
          {
            $guid = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
          }

          #`print "admin command: slot ${slot} name ${name} aname ${aname} acmdargs ${acmd} acmdargs ${acmdargs}\n";

          if( $acmd eq "seen" )
          {
            my $seenstring = $acmdargs;
            print( "Cmd: ${name} /seen ${seenstring}\n" );
            $seenstring = lc( $seenstring );
            my $seenstringq = $db->quote( "\%" . $seenstring . "\%" );
            my $q = $db->prepare("select * from seen where name like ${seenstringq} order by time desc" );
            $q->execute;

            my $rescount = 0;
            while( my $ref = $q->fetchrow_hashref( ) )
            {
              last if( $rescount > 3 );
              my $seenname = $ref->{'name'};
              my $seentime = $ref->{'time'};
              my $seencount = $ref->{'count'};
              replyToPlayer( $slot, "^3seen:^7 User ${seenname} seen ${seencount} times, last: ${seentime}" );
              ++$rescount;
            }

            my $ref = $q->fetchrow_hashref( );
            if( $rescount > 0 && $ref )
            {
              replyToPlayer( $slot, "^3seen:^7 Too many results to display. Try a more specific query." );
            }
            elsif( $rescount == 0 )
            {
              replyToPlayer( $slot, "^3seen:^7 User ${seenstring} not found" );
            }
          }
          elsif( $acmd eq "memo" )
          {
            if( $acmdargs =~ /^([\w]+)/ )
            {
              my $memocmd = lc( $1 );
              print( "Cmd: ${name} /memo ${acmdargs}\n" );

              if( $memocmd eq "send" )
              {
                if( $acmdargs =~ /^([\w]+) ([^ ]+|"[.]+") (.*)/ )
                {
                  my $memoname = lc( $2 );
                  $memoname =~ s/\"//g;
                  my $memonamelq = $db->quote( "\%" . $memoname . "\%" );
                  my $memo = $3;
                  my $memoq = $db->quote( $memo );

                  my $q = $db->prepare( "select * from seen where name LIKE ${memonamelq} AND time > datetime( ${timestamp}, \'-3 months\')" );
                  $q->execute;

                  my @matches;
                  my $lastmatch;
                  my $exact = 0;
                  while( my $ref = $q->fetchrow_hashref( ) )
                  {
                    $exact = 1 if( $ref->{ 'name' } eq $memoname );
                    $lastmatch = $ref->{ 'name' };
                    push( @matches, $ref->{ 'name' } );
                  }

                  if( $exact )
                  {
                    my $memonameq = $db->quote( $memoname );
                    $db->do( "INSERT INTO memo (name, sentby, sentbyg, senttime, msg) VALUES (${memonameq}, ${nameq}, \'${guid}\', ${timestamp}, ${memoq})" );
                    replyToPlayer( $slot, "^3memo:^7 memo left for ${memoname}" );
                  }
                  elsif( scalar @matches == 1 )
                  {
                    my $memonameq = $db->quote( $lastmatch );
                    $db->do( "INSERT INTO memo (name, sentby, sentbyg, senttime, msg) VALUES (${memonameq}, ${nameq}, \'${guid}\', ${timestamp}, ${memoq})" );
                    replyToPlayer( $slot, "^3memo:^7 memo left for ${lastmatch}" );
                  }
                  elsif( scalar @matches > 1 )
                  {
                    replyToPlayer( $slot, "^3memo:^7 multiple matches. Be more specific: " . join( ", ", @matches ) );
                  }
                  else
                  {
                    replyToPlayer( $slot, "^3memo:^7 invalid user: ${memoname} not seen in last 3 months. Use EXACT names!" );
                  }
                }
                else
                {
                  replyToPlayer( $slot, "^3memo:^7 syntax: memo send <name> <message>" );
                }
              }
              elsif( $memocmd eq "listsent" )
              {
                my $q = $db->prepare( "select * from memo where sentbyg = \'${guid}\' order by senttime asc" );
                $q->execute;

                my @memos;
                my $max = 3;
                while( my $ref = $q->fetchrow_hashref( ) )
                {
                  my %thismemo;
                  $thismemo{ 'ID' } = $ref->{ 'ID' };
                  $thismemo{ 'name' } = $ref->{ 'name' };
                  $thismemo{ 'msg' } = $ref->{ 'msg' };

                  push( @memos, \%thismemo );
                }
                $max = scalar @memos if( scalar @memos < $max );
                
                replyToPlayer( $slot, "^3memo:^7 showing ${max} of " . scalar @memos . " sent memos" );

                for( my $i = 0; $i < $max; $i++ )
                {
                  my $id = $memos[ $i ]{ 'ID' };
                  my $to = $memos[ $i ]{ 'name' };
                  my $msg = $memos[ $i ]{ 'msg' };
                  replyToPlayer( $slot, " ID: ${id} To: ${to} Msg: ${msg}" );
                }
              }
              elsif( $memocmd eq "unsend" )
              {
                if( $acmdargs =~ /^([\w]+) ([\d]+)/ )
                {
                  my $memoID = $2;
                  my $memoIDq = $db->quote( $memoID );

                  my $count = $db->do( "DELETE FROM memo WHERE sentbyg = \'${guid}\' AND ID = ${memoIDq}" );
                  if( $count ne "0E0" )
                  {
                    replyToPlayer( $slot, "^3memo:^7 deleted sent memo ${memoID}" );
                  }
                  else
                  {
                    replyToPlayer( $slot, "^3memo:^7 invalid memoID ${memoID}" );
                  }
                }
                else
                {
                  replyToPlayer( $slot, "^3memo:^7 syntax: memo unsend <memoID>" );
                }

              }
              else
              {
                replyToPlayer( $slot, "^3memo:^7 commands: send, listsent, unsend" );
              }
            }
            else
            {
              replyToPlayer( $slot, "^3memo:^7 commands: send, listsent, unsend" );
            }
          }
          elsif( $acmd eq "geoip" )
          {
            my $gipip;
            my $gipname;
            print( "Cmd: ${name} /geoip ${acmdargs}\n" );

            if( $acmdargs =~ /^([\d]+)$/ )
            {
              my $gipslot = $1;
              if( $gipslot < 64 && $connectedUsers[ $gipslot ]{ 'IP' } )
              {
                $gipip = $connectedUsers[ $gipslot ]{ 'IP' };
                $gipname = $connectedUsers[ $gipslot ]{ 'name' };
              }
              else
              {
                replyToPlayer( $slot, "^3geoip:^7 invalid or unused slot #${gipslot}" );
                next;
              }
            }
            elsif( $acmdargs =~ /^([0-9.]+)/ )
            {
              $gipip = $gipname = $1;
            }
            else
            {
              replyToPlayer( $slot, "^3geoip:^7 usage: geoip <slot#|IP>" );
              next;
            }
            my $gipinfo = $gi->get_city_record_as_hash( $gipip );
            my $gipcountry = $$gipinfo{ 'country_name' };
            my $gipcity = $$gipinfo{ 'city' };
            my $gipregion = $$gipinfo{ 'region' };
            my $gipiaddr = inet_aton( $gipip );
            my $giphostname = gethostbyaddr( $gipiaddr, AF_INET );
            $gipcountry ||= "";
            $gipcity ||= "";
            $gipregion ||= "";
            replyToPlayer( $slot, "^3geoip:^7 ${gipname} connecting from ${giphostname} ${gipcity} ${gipregion} ${gipcountry}" );
          }
          elsif( $acmd eq "l1" )
          {
            if( $acmdargs =~ /^([\d]+)$/ )
            {
              my $targslot = $1;

              print( "Cmd: ${name} /l1 ${acmdargs}\n" );
              if( $targslot < 64 && 
                  $connectedUsers[ $targslot ]{ 'connected' } == CON_CONNECTED && 
                  $connectedUsers[ $targslot ]{ 'IP' } )
              {
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
              else
              {
                replyToPlayer( $slot, "^3l1:^7 invalid or unused slot #${targslot}" );
                next;
              }
            }
            else
            {
              replyToPlayer( $slot, "^3l1:^7 usage: l1 <slot# of level 0 user>" );
              next;
            }
          }
        }
        else
        {
          print( "Parse failure on ${arg0} ${args}\n" );
        }
      }
      #`elsif( $arg0 eq "Say" || $arg0 eq "SayTeam" || $arg0 eq "AdminMsg" )
      #`{
        #`$args =~ /$sayRegExp/;
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
      print "End of backlog\n";
      exit;
    }

    if( $startupBacklog )
    {
      $startupBacklog = 0;
    }

    seek( FILE, 0, 1 ); 
    sleep 1; 
  }
}

close( FILE );

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
  if( $disablerespond || $backlog || $startupBacklog )
  {
    return;
  }

  $string =~ s/'//g;
# `screen -S tremded -p 0 -X stuff $\'\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10\10${string}\n\'`

  my $outstring = `echo -e \'\xff\xff\xff\xffrcon ${rcpass} ${string}\' | nc -w 0 -u ${ip} ${port}`;
  if( $outstring )
  {
    #print "Output: $outstring";
  }
  print "Sent: ${string}\n";
  return $outstring;
}

sub updateSeen
{
  my( $name, $timestamp ) = @_;
  my $nameq = lc( $name );
  $nameq = $db->quote( $nameq );
  my $q = $db->prepare("select * from seen where name = ${nameq}");
  $q->execute;

  if( my $ref = $q->fetchrow_hashref( ) )
  {
    my $count = $ref->{'count'};
    $count++;
    $db->do( "UPDATE seen SET time=${timestamp}, count=${count} WHERE name=${nameq}" );
  }
  else
  {
    $db->do( "INSERT INTO seen (name, time, count) VALUES (${nameq}, ${timestamp}, 1)" );
  }
}

sub memocheck
{
  my( $slot ) = @_;
  my $name = $connectedUsers[ $slot ]{ 'name' };

  my $memonameq = $db->quote( lc( $name ) );

  my $q = $db->prepare("SELECT * FROM memo WHERE name = ${memonameq}" );
  $q->execute;

  while( my $ref = $q->fetchrow_hashref( ) )
  {
    my $senttime = $ref->{ 'senttime' };
    my $memo = $ref->{ 'msg' };
    my $sentby = $ref->{ 'sentby' };
    replyToPlayer( $slot, "Memo from user ${sentby} [${senttime}]: ${memo}" );
  }
  $db->do( "DELETE FROM memo WHERE name = ${memonameq}" );

  my $aname = $connectedUsers[ $slot ]{ 'aname' };
  if( $aname && lc( $aname ) ne lc( $name ) ) 
  {
    my $memonameq = $db->quote( lc( $aname ) );
    my $q = $db->prepare("SELECT * FROM memo WHERE name = ${memonameq}" );
    $q->execute;

    while( my $ref = $q->fetchrow_hashref( ) )
    {
      my $senttime = $ref->{'senttime'};
      my $memo = $ref->{'msg'};
      my $sentby = $ref->{'sentby'};
      replyToPlayer( $slot, "Memo from user ${sentby} [${senttime}]: ${memo}" );
    }
    $db->do( "DELETE FROM memo WHERE name = ${memonameq}" );
  }
}

sub timestamp
{
  if( $backlog )
  {
    my $out = $servertsstr;
    $out =~ s/\//-/g;
    return( $db->quote( $out ) );
  }
  my $q = $db->prepare( "select DATETIME('now','localtime')" );
  $q->execute;
  my $out = $q->fetchrow_array( );

  $out = $db->quote( $out );
  return $out;
}
