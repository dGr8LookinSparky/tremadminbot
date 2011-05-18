use common::sense;
use Socket;
use Geo::IP::PurePerl;

our @connectedUsers;

my $GeoIP;

BEGIN
{
  foreach( qw/Geo::IP Geo::IP::PurePerl/ )
  {
    eval( "use $_;" );
    unless( $@ )
    {
      $GeoIP = $_;
      last;
    }
  }
}
die( "No compatible Geo::IP module found\n" ) unless( $GeoIP );

# Where do we store the geoIP database
our $gipdb ||= "/usr/local/share/GeoIP/GeoLiteCity.dat";

my $gi = $GeoIP->open( $gipdb, GEOIP_STANDARD );

sub getrecord
{
  return $gi->record_by_addr( $_[0] );
}

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my $gipip;
  my $gipname;
  print( "Cmd: $user->{name} /geoip @$acmdargs\n" );

  if( $acmdargs->[ 0 ] =~ /^([\d]+\.[\d]+\.[\d]+\.[\d]+)/ )
  {
    $gipip = $gipname = $1;
  }
  elsif( my $giptarg = unenclose( $acmdargs->[ 0 ] ) )
  {
    my $err = "";
    my $gipslot = slotFromString( $giptarg, 0, \$err );
    if( $gipslot < 0 )
    {
      replyToPlayer( $user, "^3geoip:^7 ${err}" );
      return;
    }

    if( $connectedUsers[ $gipslot ]{ 'IP' } )
    {
      $gipip = $connectedUsers[ $gipslot ]{ 'IP' };
      $gipname = $connectedUsers[ $gipslot ]{ 'name' };
    }
    else
    {
      replyToPlayer( $user, "^3geoip:^7 Unused slot #${giptarg}" );
      return;
    }
  }
  else
  {
    replyToPlayer( $user, "^3geoip:^7 usage: geoip <name|slot#|IP>" );
    return;
  }
  if( my $gipinfo = getrecord( $gipip ) )
  {
    my $gipcountry = $gipinfo->country_name;
    my $gipcity = $gipinfo->city;
    my $gipregion = $gipinfo->region;
    my $gipiaddr = inet_aton( $gipip );
    my $giphostname = gethostbyaddr( $gipiaddr, AF_INET );
    $giphostname ||= "";
    $gipcountry ||= "";
    $gipcity ||= "";
    $gipregion ||= "";
    replyToPlayer( $user, "^3geoip:^7 ${gipname} connecting from ${giphostname} ${gipcity} ${gipregion} ${gipcountry}" );
  }
  else
  {
    replyToPlayer( $user, "^3geoip: ^7$gipname^7 not in GeoIP database" );
  }
};
