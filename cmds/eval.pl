sub
{
  my( $user, $acmdargs, $timestamp, $db ) = @_;

  print( "Cmd: $user->{name} /eval @$acmdargs\n" );

  my @response = eval( "@$acmdargs" );
  @response = $@ =~ /^(.*) at .*? line \d+/ if( $@ );
  @response = split( /\n/, "@response" );
  replyToPlayer( $user, $_ ) foreach( @response );
};
