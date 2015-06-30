use Net::Async::HTTP::Server;
use JSON qw( decode_json );
use URI::Escape qw( uri_unescape );

use SyTest::HTTPClient;

struct Awaiter => [qw( pathmatch filter future )];

prepare "Environment closures for receiving HTTP pokes",
   requires => [qw( )],

   provides => [qw( internal_server_port test_http_server_uri_base await_http_request )],

   do => sub {
      my $listen_host = "localhost";

      # List of Awaiter structs
      my @pending_awaiters;

      my $http_server = Net::Async::HTTP::Server->new(
         on_request => sub {
            my ( $self, $request ) = @_;

            # TODO: This should be a parameter of NaH:Server
            bless $request, "SyTest::HTTPServer::Request" if ref( $request ) eq "Net::Async::HTTP::Server::Request";

            my $method = $request->method;
            my $path = uri_unescape $request->path;

            my $content = $request->body;
            if( ( $request->header( "Content-Type" ) // "" ) eq "application/json" ) {
               $content = decode_json $content;
            }

            if( $CLIENT_LOG ) {
               print STDERR "\e[1;32mReceived Request\e[m for $method $path:\n";
               #TODO log the HTTP Request headers
               print STDERR "  $_\n" for split m/\n/, $request->body;
               print STDERR "-- \n";
            }

            foreach my $idx ( 0 .. $#pending_awaiters ) {
               my $awaiter = $pending_awaiters[$idx];

               my $pathmatch = $awaiter->pathmatch;
               next unless ( !ref $pathmatch and $path eq $pathmatch ) or
                           ( ref $pathmatch  and $path =~ $pathmatch );

               next if $awaiter->filter and not $awaiter->filter->( $content );

               splice @pending_awaiters, $idx, 1, ();
               $awaiter->future->done( $content, $request );
               return;
            }

            warn "Received spurious HTTP request to $path\n";
         }
      );
      $loop->add( $http_server );

      my $await_http_request = sub {
         my ( $pathmatch, $filter ) = @_;
         # Carp::shortmess is no good here as every test runs in the 'main' package
         my $caller = sprintf "%s line %d.", (caller)[1,2];

         my $f = $loop->new_future;

         push @pending_awaiters, Awaiter( $pathmatch, $filter, $f );

         return Future->wait_any(
            $f,

            delay( 10 )
               ->then_fail( "Timed out waiting for an HTTP request matching $pathmatch at $caller\n" ),
         );
      };

      provide await_http_request => $await_http_request;

      my $http_client;

      $http_server->listen(
         addr => {
            family   => "inet",
            socktype => "stream",
            port     => 0,
         },
      )->then( sub {
         my ( $listener ) = @_;
         my $sockport = $listener->read_handle->sockport;

         provide internal_server_port => $sockport;

         my $uri_base = "http://$listen_host:$sockport";

         provide test_http_server_uri_base => $uri_base;

         $http_client = SyTest::HTTPClient->new(
            uri_base => $uri_base,
         );
         $loop->add( $http_client );

         Future->needs_all(
            Future->wait_any(
               $await_http_request->( "/http_server_self_test", sub {1} ),

               delay( 10 )
                  ->then_fail( "Timed out waiting for request" ),
            )->then( sub {
               my ( $request_body, $request ) = @_;

               $request_body->{some_key} eq "some_value" or
                  die "Expected JSON with {\"some_key\":\"some_value\"}";

               $request->respond_json( {} );
               Future->done();
            }),

            $http_client->do_request_json(
               method  => "POST",
               uri     => "/http_server_self_test",
               content => {
                  some_key => "some_value",
               },
            )->then_done(1),
         )
      })->then( sub {
         Future->needs_all(
            Future->wait_any(
               $await_http_request->( "/http_server_self_test", sub {1} ),

               delay( 10 )
                  ->then_fail( "Timed out waiting for request" ),
            )->then( sub {
               my ( $request_body, $request ) = @_;

               $request->respond_json( {
                  response_key => "response_value",
               } );
               Future->done();
            }),

            $http_client->do_request_json(
               method => "POST",
               uri     => "/http_server_self_test",
               content => {},
            )->then( sub {
               my ( $response_body ) = @_;

               $response_body->{response_key} eq "response_value" or
                  die "Expected JSON with {\"response_key\":\"response_value\"}";

               Future->done(1);
            }),
         )
      })
   };

# A somewhat-hackish way to give NaH:Server::Request objects a ->respond_json method
package SyTest::HTTPServer::Request;
use 5.014; # ${^GLOBAL_PHASE}
use base qw( Net::Async::HTTP::Server::Request );

use JSON qw( encode_json );

use Carp;

sub DESTROY
{
   return if ${^GLOBAL_PHASE} eq "DESTRUCT";
   my $self = shift or return;
   return if $self->{__responded};
   carp "Destroying unresponded HTTP request to ${\$self->path}";
}

sub respond
{
   my $self = shift;
   $self->{__responded}++;
   $self->SUPER::respond( @_ );
}

sub respond_json
{
   my $self = shift;
   my ( $json ) = @_;

   my $response = HTTP::Response->new( 200 );
   $response->add_content( encode_json $json );
   $response->content_type( "application/json" );
   $response->content_length( length $response->content );

   $self->respond( $response );
}