use SyTest::Synapse;

use Cwd qw( abs_path );

my $N_HOMESERVERS = 2;

sub extract_extra_args
{
   my ( $idx, $args ) = @_;

   return map {
      if( m/^\[(.*)\]$/ ) {
         # Extract the $idx'th element from a comma-separated list, or use the final
         my @choices = split m/,/, $1;
         $idx < @choices ? $choices[$idx] : $choices[-1];
      }
      else {
         $_;
      }
   } @$args;
}

my @synapses;

END {
   $OUTPUT->diag( "Killing synapse servers " ) if @synapses;

   foreach my $synapse ( values @synapses ) {
      $synapse->kill( 'INT' );
   }
}

push our @EXPORT, qw( HOMESERVER_INFO );

our @HOMESERVER_INFO = map {
   my $idx = $_;

   fixture(
      requires => [ $main::TEST_SERVER_INFO, @main::AS_INFO ],

      setup => sub {
         my ( $test_server_info, @as_infos ) = @_;

         my $secure_port   = main::alloc_port( "synapse[$idx]" );
         my $unsecure_port = main::alloc_port( "synapse[$idx].unsecure" );

         my @extra_args = extract_extra_args( $idx, $SYNAPSE_ARGS{extra_args} );

         my $location = $WANT_TLS ?
            "https://localhost:$secure_port" :
            "http://localhost:$unsecure_port";

         my $info = ServerInfo( "localhost:$secure_port", $location );

         my $synapse = SyTest::Synapse->new(
            synapse_dir   => $SYNAPSE_ARGS{directory},
            hs_dir        => abs_path( "localhost-$idx" ),
            ports         => {
               client          => $secure_port,
               client_unsecure => $unsecure_port,
               metrics         => main::alloc_port( "synapse[$idx].metrics" ),

               pusher_metrics => main::alloc_port( "pusher[$idx].metrics" ),
               pusher_manhole => main::alloc_port( "pusher[$idx].manhole" ),

               synchrotron         => main::alloc_port( "synchrotron[$idx]" ),
               synchrotron_metrics => main::alloc_port( "synchrotron[$idx].metrics" ),
               synchrotron_manhole => main::alloc_port( "synchrotron[$idx].manhole" ),
            },
            output        => $OUTPUT,
            print_output  => $SYNAPSE_ARGS{log},
            extra_args    => \@extra_args,
            python        => $SYNAPSE_ARGS{python},
            coverage      => $SYNAPSE_ARGS{coverage},
            dendron       => $SYNAPSE_ARGS{dendron},
            pusher        => $SYNAPSE_ARGS{pusher},
            synchrotron   => $SYNAPSE_ARGS{synchrotron},
            ( scalar @{ $SYNAPSE_ARGS{log_filter} } ?
               ( filter_output => $SYNAPSE_ARGS{log_filter} ) :
               () ),

            config => {
               # Config for testing recaptcha. 90jira/SYT-8.pl
               recaptcha_siteverify_api => $test_server_info->client_location .
                                              "/recaptcha/api/siteverify",
               recaptcha_public_key     => "sytest_recaptcha_public_key",
               recaptcha_private_key    => "sytest_recaptcha_private_key",

               use_insecure_ssl_client_just_for_testing_do_not_use => 1,
               report_stats => "False",
               user_agent_suffix => $location,
               allow_guest_access => "True",
            },
         );
         $loop->add( $synapse );

         if( $idx == 0 ) {
            # Configure application services on first instance only
            my @confs;

            foreach my $idx ( 0 .. $#as_infos ) {
               my $as_info = $as_infos[$idx];

               my $appserv_conf = $synapse->write_yaml_file( "appserv-$idx.yaml", {
                  id       => $as_info->id,
                  url      => $test_server_info->client_location . $as_info->path,
                  as_token => $as_info->as2hs_token,
                  hs_token => $as_info->hs2as_token,
                  sender_localpart => $as_info->localpart,
                  namespaces => {
                     users => [
                        { regex => '@astest-.*', exclusive => "true" },
                     ],
                     aliases => [
                        { regex => '#astest-.*', exclusive => "true" },
                     ],
                     rooms => [],
                  }
               } );

               push @confs, $appserv_conf;

               # Now we can fill in the AS info's user_id
               $as_info->user_id = sprintf "@%s:localhost:%d",
                  $as_info->localpart, $secure_port;
            }

            $synapse->append_config(
               app_service_config_files => \@confs,
            );
         }

         $synapse->start;

         push @synapses, $synapse;

         Future->wait_any(
            $synapse->started_future,

            $loop->delay_future( after => 20 )
               ->then_fail( "Synapse server on port $secure_port failed to start" ),
         )->then_done( $info );
      },
   );
} 0 .. $N_HOMESERVERS-1;
