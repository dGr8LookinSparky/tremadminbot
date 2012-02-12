use common::sense;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  if( open( my $fh, '<', $acmdargs ) )
  {
    while( <$fh> )
    {
      chomp;
      next if( $_ eq '' );
      replyToPlayer( $user, $_ );
    }
    close( $fh );
  }
  else
  {
    replyToPlayer( $user, "^3cat:^7 $acmdargs $!" );
  }
};
