# vim:set sw=4 ts=4 sts=4 ft=perl expandtab:
package Lufi;
use Mojo::Base 'Mojolicious';
use Net::LDAP;
use Apache::Htpasswd;

$ENV{MOJO_MAX_WEBSOCKET_SIZE} = 100485760; # 10 * 1024 * 1024 = 10MiB

# This method will run once at server start
sub startup {
    my $self = shift;
    my $entry;

    my $config = $self->plugin('Config' => {
        default =>  {
            provisioning       => 100,
            provis_step        => 5,
            length             => 10,
            token_length       => 32,
            secrets            => ['hfudsifdsih'],
            default_delay      => 0,
            max_delay          => 0,
            mail               => {
                how => 'sendmail'
            },
            mail_sender        => 'no-reply@lufi.io',
            theme              => 'default',
            upload_dir         => 'files',
            session_duration   => 3600,
            allow_pwd_on_files => 0,
            dbtype             => 'sqlite',
        }
    });

    die "You need to provide a contact information in lufi.conf!" unless (defined($self->config('contact')));

    # Themes handling
    shift @{$self->renderer->paths};
    shift @{$self->static->paths};
    if ($config->{theme} ne 'default') {
        my $theme = $self->home->rel_file('themes/'.$config->{theme});
        push @{$self->renderer->paths}, $theme.'/templates' if -d $theme.'/templates';
        push @{$self->static->paths}, $theme.'/public' if -d $theme.'/public';
    }
    push @{$self->renderer->paths}, $self->home->rel_file('themes/default/templates');
    push @{$self->static->paths}, $self->home->rel_file('themes/default/public');

    # Mail config
    my $mail_config = {
        type     => 'text/plain',
        encoding => 'quoted-printable',
        how      => $self->config('mail')->{'how'}
    };
    $mail_config->{howargs} = $self->config('mail')->{'howargs'} if (defined $self->config('mail')->{'howargs'});

    $self->plugin('Mail' => $mail_config);

    # Internationalization
    my $lib = $self->home->rel_file('themes/'.$config->{theme}.'/lib');
    eval qq(use lib "$lib");
    $self->plugin('I18N');

    # Debug
    $self->plugin('DebugDumperHelper');

    # Check htpasswd file existence
    die 'Unable to read '.$self->config('htpasswd') if (defined($self->config('htpasswd')) && !-r $self->config('htpasswd'));

    # Authentication (if configured)
    $self->plugin('authentication' =>
        {
            autoload_user => 1,
            session_key   => 'Dolomon',
            load_user     => sub {
                my ($c, $username) = @_;

                return $username;
            },
            validate_user => sub {
                my ($c, $username, $password, $extradata) = @_;

                if (defined($c->config('ldap'))) {
                    my $ldap = Net::LDAP->new($c->config->{ldap}->{uri});
                    my $mesg = $ldap->bind($c->config->{ldap}->{bind_user}.$c->config->{ldap}->{bind_dn},
                        password => $c->config->{ldap}->{bind_pwd}
                    );

                    $mesg->code && die $mesg->error;

                    $mesg = $ldap->search(
                        base   => $c->config->{ldap}->{user_tree},
                        filter => "(&(uid=$username)".$c->config->{ldap}->{user_filter}.")"
                    );

                    if ($mesg->code) {
                        $c->app->log->error($mesg->error);
                        return undef;
                    }

                    # we filtered out, but did we actually get a non-empty result?
                    $entry = $mesg->shift_entry;
                    if (!defined $entry) {
                        $c->app->log->info("[LDAP authentication failed] - User $username filtered out, IP: ".$c->ip);
                        return undef;
                    }

                    # Now we know that the user exists, and that he is authorized by the filter
                    $mesg = $ldap->bind('uid='.$username.$c->config->{ldap}->{bind_dn},
                        password => $password
                    );

                    if ($mesg->code) {
                        $c->app->log->info("[LDAP authentication failed] login: $username, IP: ".$c->ip);
                        $c->app->log->error("[LDAP authentication failed] ".$mesg->error);
                        return undef;
                    }

                    $c->app->log->info("[LDAP authentication successful] login: $username, IP: ".$c->ip);
                } elsif (defined($c->config('htpasswd'))) {
                    my $htpasswd = new Apache::Htpasswd({passwdFile => $c->config->{htpasswd},
                                                 ReadOnly   => 1}
                                                );
                    if (!$htpasswd->htCheckPassword($username, $password)) {
                        return undef;
                    }
                    $c->app->log->info("[Simple authentication successful] login: $username, IP: ".$c->ip);
                }

                return $username;
            }
        }
    );
    if (defined($self->config('ldap')) || defined($self->config('htpasswd'))) {
        $self->app->sessions->default_expiration($self->config('session_duration'));
    }

    # Secrets
    $self->secrets($self->config('secrets'));

    # Helpers
    $self->plugin('Lufi::Plugin::Helpers');
    # Hooks
    $self->hook(
        after_dispatch => sub {
            shift->provisioning();
        }
    );

    # For the first launch (after, this isn't really useful)
    $self->provisioning();

    # Create directory if needed
    mkdir($self->config('upload_dir'), 0700) unless (-d $self->config('upload_dir'));
    die ('The upload directory ('.$self->config('upload_dir').') is not writable') unless (-w $self->config('upload_dir'));

    # Default layout
    $self->defaults(layout => 'default');

    # Router
    my $r = $self->routes;

    # Page for files uploading
    $r->get('/' => sub {
        my $c = shift;
        if ((!defined($c->config('ldap')) && !defined($c->config('htpasswd'))) || $c->is_user_authenticated) {
            $c->render(template => 'index');
        } else {
            $c->redirect_to('login');
        }
    })->name('index');

    if (defined $self->config('ldap') || defined $self->config('htpasswd')) {
        # Login page
        $r->get('/login' => sub {
            my $c = shift;
            if ($c->is_user_authenticated) {
                $c->redirect_to('index');
            } else {
                $c->render(template => 'login');
            }
        });
        # Authentication
        $r->post('/login' => sub {
            my $c = shift;
            my $login = $c->param('login');
            my $pwd   = $c->param('password');

            if($c->authenticate($login, $pwd)) {
                $c->redirect_to('index');
            } elsif (defined $entry) {
                    $c->stash(msg => $c->l('Please, check your credentials: unable to authenticate.'));
                    $c->render(template => 'login');
                } else {
                    $c->stash(msg => $c->l('Sorry mate, you are not authorised to use that service. Contact your sysadmin if you think there\'s a glitch in the matrix.'));
                    $c->render(template => 'login');
            }
        });
        # Logout page
        $r->get('/logout' => sub {
            my $c = shift;
            if ($c->is_user_authenticated) {
                $c->logout;
            }
            $c->render(template => 'logout');
        })->name('logout');
    }

    # About page
    $r->get('/about' => sub {
        shift->render(template => 'about');
    })->name('about');

    # Get instance stats
    $r->get('/fullstats')
        ->to('Misc#fullstats')
        ->name('fullstats');

    # Get a file
    $r->get('/r/:short')->
        to('Files#r')->
        name('render');

    # List of files (use localstorage, so the server know nothing about files)
    $r->get('/files' => sub {
        my $c = shift;
        if ((!defined($c->config('ldap')) && !defined($c->config('htpasswd'))) || $c->is_user_authenticated) {
            $c->render(template => 'files');
        } else {
            $c->redirect_to('login');
        }
    })->name('files');

    # Get counter informations about a file
    $r->post('/c')->
        to('Files#get_counter')->
        name('counter');

    # Get counter informations about a file
    $r->get('/d/:short/:token')->
        to('Files#delete')->
        name('delete');

    # Get some informations about delays
    $r->get('/delays' => sub {
        shift->render(template => 'delays');
    })->name('delays');

    # Get mail page
    $r->get('/m')->
        to('Mail#render_mail')->
        name('mail');

    # Submit mail
    $r->post('/m')->
        to('Mail#send_mail');

    # About page
    $r->get('/about' => sub {
        shift->render(template => 'about');
    })->name('about');

    # Upload files websocket
    $r->websocket('/upload')->
        to('Files#upload')->
        name('upload');

    # Get files websocket
    $r->websocket('/download/:short')->
        to('Files#download')->
        name('download');
}

1;
