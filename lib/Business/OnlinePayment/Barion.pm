package Business::OnlinePayment::Barion;

use parent 'Business::OnlinePayment::HTTPS';
use strict;

use common::sense;
use Carp;
use JSON::XS;
use LWP::UserAgent;

# ABSTRACT: Online payment processing via Barion
our $VERSION = 0.1.0;
our $API_VERSION = 2;

our %defaults = (
    server => 'api.barion.com',
    port => 443,
);

our %info = (
    'info_compat'           => '0.01',
    'gateway_name'          => 'Barion',
    'gateway_url'           => 'http://www.barion.com/',
    'module_version'        => $VERSION,
    'supported_types'       => [ qw( CC ) ],
    'token_support'         => 0, #card storage/tokenization support
    'test_transaction'      => 1, #set true if ->test_transaction(1) works
    'supported_actions'     => [
        'Normal Authorization',
        'Query',
    ]
);

our %content_defaults = (
    payment => {
        payment_window => '00:30:00',
        guest_checkout => 'True',
        funding_sources => [ "All" ],
        locale => 'hu-HU',
        item_description => '',
        currency => 'HUF',
    },
);

my $ua = LWP::UserAgent->new();

sub _info {
    return \%info;
}

sub set_defaults {
    my $self = shift;
    my %data = @_;
    $self->{$_} = $defaults{$_} for keys %defaults;

    $self->build_subs(qw/http_args response qr_url gateway_url/);
}


sub submit {
    my $self = shift;
    my $content = $self->{_content};

    # do not allow submitting same object twice
    croak 'submitting same object twice is not allowed' if $self->{_dirty}; $self->{_dirty} = 1;

    # Turn the data into a format usable by the online processor
    croak 'no action parameter defined in content' unless exists $self->{_content}->{action};

    my %barion_api_args = (
        # credentials
        login            => 'POSGuid',
        password         => 'POSKey',

        currency         => 'Currency',
        payment_window   => 'PaymentWindow',
        guest_checkout   => 'GuestCheckout',
        funding_sources  => 'FundingSources',
        po_number        => 'PaymentRequestId',
        invoice_number   => 'OrderNumber',
        email            => 'PayerHint',
        redirect_url     => 'RedirectUrl',
        callback_url     => 'CallbackUrl',
        locale           => 'Locale',

        payment_id       => 'PaymentId',
    );

    # Login information, default to constructor values
    $content->{login}    ||= $self->{login};
    $content->{password} ||= $self->{password};

    # Set content defaults
    if ($content->{action} =~ /authorization/) {
        $content->{$_} ||= $content_defaults{'payment'}->{$_} for keys %{$content_defaults{'payment'}};
    }

    # remove phone special characters
    $content->{phone} =~ s/[^0-9]//g if $content->{phone};

    # Remap the fields to their API counterparts
    $self->remap_fields(%barion_api_args);

    my @basic_args = qw(login password);
    my %actions = (
        'normal authorization' => {
            path => 'Payment/Start',
            method => 'post',
            content => {
                PaymentType => 'Immediate',
            },
            require => [qw(po_number amount)],
            args => [qw(Transactions ShippingAddress)],
        },
        'query' => {
            path => 'Payment/GetPaymentState',
            method => 'get',
            require => [qw(payment_id)],
        },
    );

    my $action = $actions{$content->{action}} || croak "action not supported: ".$content->{action};

    # by action defaults for content
    $content->{$_} = $action->{content}{$_} for keys %{$action->{content} || {}};

    my @undefs = grep { ! defined $content->{$_} } (@basic_args, @{$action->{require} || []});
    croak "missing required args: ". join(',',@undefs) if scalar @undefs;

    if ($content->{action} =~ /authorization/) { # payment
        $self->_build_shipping_address();
        $self->_build_transactions();
    }

    # Define all possible arguments for http request
    my @all_http_args = (values %barion_api_args, @{$action->{args} || []});

    # Construct the HTTP parameters by selecting the ones which are defined from all_http_args
    my %http_req_args = map { $_ => $content->{$_} }
                        grep { defined $content->{$_} }
                        map { $barion_api_args{$_} || $_ } @all_http_args;

    $self->{server} = 'api.test.barion.com' if $self->test_transaction;

    $self->{path} = sprintf '/v%d/%s', $API_VERSION, $action->{path};

    # Save the http args for later inspection
    $self->http_args(\%http_req_args);

    my $res;
    if ($action->{method} eq 'post') {
        my $json = encode_json(\%http_req_args);
        $res = $ua->post($self->url, Content => $json, Content_Type => 'application/json');
    }
    elsif ($action->{method} eq 'get') {
        my $req = URI->new($self->url);
        $req->query_form(%http_req_args);
        $res = $ua->get($req);
    }
    $self->server_response([$res->{_rc}, $res->{_headers}, $res->decoded_content]);
    $self->response_code($res->{_rc});
    $self->response_page($res->decoded_content);
    $self->is_success($res->is_success ? 1 : 0);

    my $response = eval { decode_json($self->response_page) };
    $self->response($response);

    if ($self->is_success) {
        $self->result_code(0);
        $self->authorization($response->{PaymentId}) if $response->{PaymentId};
        $self->qr_url($response->{QRUrl}) if $response->{QRUrl};
        $self->gateway_url($response->{GatewayUrl}) if $response->{GatewayUrl};
    }
    else {
        $self->result_code($self->response_code);
        if ($response->{Errors} && @{$response->{Errors}} ) {
            $self->error_message($response->{Errors}[0]{ErrorCode});
        }
    }
}

sub _build_shipping_address {
    my ($self) = @_;

    my %fields = (
        name    => 'FullName',
        country => 'Country',
        city    => 'City',
        state   => 'Region',
        zip     => 'Zip',
        address => 'Street',
        phone   => 'Phone',
    );

    my %address;
    for (keys %fields) {
        $address{$fields{$_}} = $self->{_content}{$_} if defined $self->{_content}{$_};
    }

    $self->{_content}{ShippingAddress} = \%address if %address;
}

sub _build_transactions {
    my ($self) = @_;

    my %fields = (
        item_name        => { name => 'Name',        default => 'Unknown item' },
        item_description => { name => 'Description', default => 'Unknown item' },
        item_image_url   => { name => 'ImageUrl',    default => '' },
        item_quantity    => { name => 'Quantity',    default => 1 },
        item_unit        => { name => 'Unit',        default => 'db' },
        item_unit_price  => { name => 'UnitPrice',   default => $self->{_content}{amount} },
        amount           => { name => 'ItemTotal',   default => $self->{_content}{amount} },
        item_sku         => { name => 'SKU',         default => '0000000000001' },
    );

    $self->{_content}{Transactions} ||= [];

    my $item = {
        map {$fields{$_}{name} =>
               $self->{_content}{$_} ||
               $fields{$_}{default}
        } keys %fields
    };

    push @{$self->{_content}{Transactions}}, {
        POSTransactionId => $self->{_content}{po_number} || time,
        Payee => $self->{_content}{merchant_email} || '',
        Total => $self->{_content}{amount},
        Items => [ $item ],
    };
}

sub url {
    my ($self) = @_;

    return sprintf "http%s://%s:%d%s",
      $self->port == 443 ? 's' : '', $self->server, $self->port, $self->path;
}

1;
__END__

=head1 NAME

Business::OnlinePayment::Barion - Online payment processing via Barion

=head1 SYNOPSYS

    use Business::OnlinePayment;

    my $tx = new Business::OnlinePayment('Barion', login => 'your POSGuid',
                                                   password => 'your POSKey' );

    $tx->test_transaction(1); # remove when migrating to production env

    # minimal payment request mode, all defaults, only payment amount, order number and email
    $tx->content(action => 'normal authorization', amount => 1999,
                 po_number => 12345, merchant_email => 'a@b.com');
    eval    { $tx->submit() };
    if ($@) { die 'failed to submit to remote because: '.$@ };

    if ( $tx->is_success() ) {
        printf 'transaction successful, redirect URL: %s, authorization code: %s\n',
            $tx->gateway_url, $tx->authorization;
    } else {
        printf 'transaction unsuccessful, error: %s\n', $tx->error_message;
    }

    # full payment transaction, values below are the defaults
    $tx->content(
        merchant_email => 'a@b.com',    # merchant e-mail address at Barion, required
        po_number => 54321,             # primary transaction identifier, required
        amount => 23.4,                 # amount to pay, required

        currency => 'HUF',              # optional currency
        locale => 'hu-HU',              # gateway site language
        payment_window => '00:30:00',   # maximum timeframe to finish payment for customer
        guest_checkout => 'True',       # allow direct card payment
        funding_sources => ['All'],     # allow any source (Barion account balance, cards)
        invoice_number => 12345,        # merchant invoice number
        email => 'user@example.com',    # customer e-mail address (fills gateway form)
        redirect_url => 'http://...',   # your site URL to go after successful/failed payment
        callback_url => 'http://...',   # URL Barion calls at various stages of payment
        address => 'Somestreet 234',    # optional customer address
        city => 'Brussels',             # optional customer city
        zip => 1000                     # optional customer zip code
        country => 'BE',                # optional customer country (iso?)
    );



=head1 DESCRIPTION

This module interfaces Business::OnlinePayment with L<Barion|http://www.barion.com>, a European Payment Provider.
It is based on the L<Barion API documentation|https://docs.barion.com/>.
