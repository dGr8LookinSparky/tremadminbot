use common::sense;

sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  print( "Cmd: $user->{name} /l0 ${acmdargs}\n" );

  my$targ ;

  if( $acmdargs eq "" )
  {
    $targ = $user;
  }
  else
  {
    my $err = "";
    $targ = findadmin( $acmdargs, \$err );
    unless( $targ )
    {
      replyToPlayer( $user, "^3l1:^7 ${err}" );
      return;
    }
  }

  if( $targ->{ 'alevel' } == 1 )
  {
    printToPlayers( "^3l0:^7 $user->{ 'name' } set $targ->{ 'name' } to level 0" );
    sendconsole( "setlevel $targ->{ 'slot' } 0" );
  }
  else
  {
    replyToPlayer( $user, "^3l0:^7 $targ->{ 'name' } is not level 1" );
    return;
  }
};