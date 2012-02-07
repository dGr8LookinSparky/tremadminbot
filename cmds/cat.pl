use common::sense;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  print( "Cmd: $user->{name} /cat $$acmdargs[ 0 ]\n" );

  if( open( my $fh, '<', $$acmdargs[ 0 ] ) )
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
    replyToPlayer( $user, "^3cat:^7 $$acmdargs[ 0 ] $!" );
  }
};
