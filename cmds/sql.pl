use common::sense;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my $q = eval { $db->prepare( "@$acmdargs" ) };
  if( $@ && $@ =~ /^(.*) at .*? line \d+/ )
  {
    replyToPlayer( $user, "^3sql:^7 $1" );
  }
  return unless( $q );
  $q->execute;
  while( my @r = $q->fetchrow_array )
  {
    replyToPlayer( $user, "  '" . join( "', '", @r ) . "'" );
  }
};
