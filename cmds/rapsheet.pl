use common::sense;
our @connectedUsers;

sub
{
  my( $user, $acmdargs, $db ) = @_;

  print( "Cmd: $user->{name} /rapsheet ${acmdargs}\n" );

  my( $targ, $param ) = shellwords( $acmdargs );
  if( $targ eq "" )
  {
    replyToPlayer( $user, "^3rapsheet:^7 usage: rapsheet <name|slot#> [GUID|IP|SUBNET]" );
    next;
  }

  my $err = "";
  my $targslot = slotFromString( $targ, 1, \$err );
  if( $targslot < 0 )
  {
    replyToPlayer( $user, "^3rapsheet:^7 ${err}" );
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
      replyToPlayer( $user, "^3rapsheet:^7 player is not connected via ipv4." );
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

  replyToPlayer( $user, "^3rapsheet:^7 ${targName}^7 offenses by ${searchtype}: Kicks: ${kicks} Bans: ${bans} Mutes: ${mutes} Denybuilds: ${denybuilds}" );
};
