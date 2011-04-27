use common::sense;

our $fortunePath ||= 'fortune';

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  my $fortune;
  unless( open( $fortune, '-|', $fortunePath ) )
  {
    replyToPlayer( $user, '^3fortune:^7 fortune is not configured properly' );
    return;
  }

  while( <$fortune> )
  {
    chomp;
    s/"/''/g;
    replyToPlayer( $user, "^3fortune:^7 $_" );
  }

  close( $fortune );
};