# $license-info}
# ${developer-info}
# ${author-info}
# ${build-info}
#
#
#
# This component is dedicated to Xrootd configuration management. It hs been designed
# to be very flexible and need no major change to handle changes in
# configuration file format, by using parsing rules to update the contents
# of configuration files. Original version is strongly based on ncm-dpmlfc,
# used to manage DPM/LFC.
#
# Configuration files are modified only if their contents need to be changed,
# not at every run of the component. In case of changes, the services depending
# on the modified files are restared.
#
# Adding support for a new configuration variable should be pretty easy.
# Basically, if this is a role specific variable, you just need add a 
# parsing rule that use it in the %xxx_config_rules
# for the configuration file.
#
# An effort has been made to document the code. Be sure to understand it before
# modifying.
#
# In case of problems, use --debug option of ncm-ncd. This will produce a lot
# of debugging information. 2 debugging levels are available (1, 2).
#
#######################################################################

package NCM::Component::${project.artifactId};

use strict;
use NCM::Component;
use vars qw(@ISA $EC);
@ISA = qw(NCM::Component);
$EC=LC::Exception::Context->new->will_store_all;

use EDG::WP4::CCM::Element;

use File::Path;
use File::Copy;
use File::Compare;
use File::Basename;
use File::stat;

use LC::Check;
use CAF::FileWriter;
use CAF::FileEditor;
use CAF::Process;

use Encode qw(encode_utf8);
use Fcntl qw(SEEK_SET);

local(*DTA);

use Net::Domain qw(hostname hostfqdn hostdomain);


# Define paths for convenience. 
use constant XROOTD_INSTALL_ROOT_DEFAULT => "";

# Define some commands explicitly
use constant SERVICECMD => "/sbin/service";

# Backup file extension
use constant BACKUP_FILE_EXT => ".old";

# Constants use to format lines in configuration files
use constant LINE_FORMAT_PARAM => 1;
use constant LINE_FORMAT_ENVVAR => 2;
use constant LINE_FORMAT_XRDCFG => 3;
use constant LINE_FORMAT_XRDCFG_SETENV => 4;
use constant LINE_FORMAT_XRDCFG_SET => 5;
use constant LINE_VALUE_AS_IS => 0;
use constant LINE_VALUE_BOOLEAN => 1;
use constant LINE_VALUE_HOST_LIST => 2;
use constant LINE_VALUE_INSTANCE_PARAMS => 3;
use constant LINE_VALUE_ARRAY => 4;
use constant LINE_VALUE_HASH_KEYS => 5;
use constant LINE_VALUE_STRING_HASH => 6;
use constant LINE_FORMAT_DEFAULT => LINE_FORMAT_PARAM;
use constant LINE_QUATTOR_COMMENT => "\t\t# Line generated by Quattor";

# Role names used here must be the same as key in other hashes.
my @xrootd_roles = (
     "disk",
     "redir",
     "fedredir",
    );
# Following hash define the maximum supported servers for each role
my %role_max_servers = (
          "disk" => 1,
          "redir" => 1,
          "fedredir" => 999,
         );


# Following hashes define parsing rules to build a configuration.
# Hash key is the line keyword in configuration file and 
# hash value is the parsing rule for the keyword value. Parsing rule format is :
#       [condition->]option_name:option_set[,option_set,...];line_fmt[;value_fmt]
#
# 'condition': an option or an option set that must exist for the rule to be applied.
#              Both option_set and option_name:option_set are accepted (see below).
#              Only one option set is allowed and only existence, not value is tested.
#
# 'option_name' is the name of an option that will be retrieved from the configuration
# 'option_set' is the set of options the option is located in (for example 'dpnsHost:dpm'
# means 'dpnsHost' option of 'dpm' option set. 'GLOBAL' is a special value for 'option_set'
# indicating that the option is a global option, instead of belonging to a specific option set.
#
# 'line_fmt' indicates the line format for the parameter : 3 formats are 
# supported :
#  - envvar : a sh shell environment variable definition (export VAR=val)
#  - param : a sh shell variable definition (VAR=val)
#  - xrdcfg : a 'keyword value' line, as used by Xrootd config files.
#  - xrdcfg_setenv : a 'setenv' line, as used by Xrootd config files.
#  - xrdcfg_set : a 'set' line, as used by Xrootd config files.
# Inline comments are not supported in xrdcfg family of formats.
# Line format has an impact on hosts list if there is one.
#
# 'value_fmt' allows special formatting of the value. This is mainly used for boolean
# values so that they are encoded as 'yes' or 'no'.
# If there are several servers for a role the option value from all the servers# is used for 'host' option, and only the server corresponding to current host
# for other options.

my $xrootd_sysconfig_file = "/etc/sysconfig/xrootd";
my %xrootd_sysconfig_rules = (
        "CMSD_INSTANCES" => "cmsdInstances:GLOBAL;".LINE_FORMAT_PARAM.";".LINE_VALUE_HASH_KEYS,
        "CMSD_%%INSTANCE%%_OPTIONS" => "cmsdInstances:GLOBAL;".LINE_FORMAT_PARAM.";".LINE_VALUE_INSTANCE_PARAMS,
        "DAEMON_COREFILE_LIMIT" => "coreMaxSize:dpm;".LINE_FORMAT_PARAM,
        "DPM_CONRETRY" => "dpmConnectionRetry:dpm;".LINE_FORMAT_PARAM,
        "DPM_HOST" => "dpmHost:dpm;".LINE_FORMAT_PARAM,
        "DPMXRD_ALTERNATE_HOSTNAMES" => "alternateNames:dpm;".LINE_FORMAT_PARAM,
        "DPNS_CONRETRY" => "dpnsConnectionRetry:dpm;".LINE_FORMAT_PARAM,
        "DPNS_HOST" => "dpnsHost:dpm;".LINE_FORMAT_PARAM,
        "XROOTD_GROUP" => "daemonGroup:GLOBAL;".LINE_FORMAT_PARAM,
        "XROOTD_INSTANCES" => "xrootdInstances:GLOBAL;".LINE_FORMAT_PARAM.";".LINE_VALUE_HASH_KEYS,
        "XROOTD_%%INSTANCE%%_OPTIONS" => "xrootdInstances:GLOBAL;".LINE_FORMAT_PARAM.";".LINE_VALUE_INSTANCE_PARAMS,
        "XROOTD_USER" => "daemonUser:GLOBAL;".LINE_FORMAT_PARAM,
       );

my %disk_config_rules = (
       );

my %redir_config_rules = (
      "dpm.defaultprefix" => "dpm->defaultPrefix:dpm;".LINE_FORMAT_XRDCFG,
      "dpm.fixedidrestrict" => "dpm->authorizedPaths:tokenAuthz;".LINE_FORMAT_XRDCFG.";".LINE_VALUE_ARRAY,
      "dpm.fqan" => "dpm->allowedFQANs:tokenAuthz;".LINE_FORMAT_XRDCFG.";".LINE_VALUE_ARRAY,
      "dpm.principal" => "dpm->principal:tokenAuthz;".LINE_FORMAT_XRDCFG,
      "dpm.replacementprefix" => "dpm->replacementPrefix:dpm;".LINE_FORMAT_XRDCFG.";".LINE_VALUE_STRING_HASH,
      "ofs.authlib" => "authzLibraries:GLOBAL;".LINE_FORMAT_XRDCFG.";".LINE_VALUE_ARRAY,
      "TTOKENAUTHZ_AUTHORIZATIONFILE" => "authzConf:tokenAuthz;".LINE_FORMAT_XRDCFG_SETENV,
     );

my %fedredir_config_rules = (
       );

my %config_rules = (
        "disk" => \%disk_config_rules,
        "redir" => \%redir_config_rules,
        "fedredir" => \%fedredir_config_rules,
       );
       
# Global variables to store component configuration
# Global context variables containing used by functions
use constant DM_INSTALL_ROOT => "";

# xroot related global variables
my %xrootd_daemon_prefix = ('head' => '',
                            'disk' => '',
                           );
# xrootd_services is used to track association between a daemon name
# (the key) and its associatated service names (can be a comma separated list).
my %xrootd_services = ('cmsd' => 'xrootd',
                       'xrootd' => 'xrootd',
                      );

# Pan path for the component configuration, variable to host the profile contents and other
# constants related to profile
use constant PANPATH => "/software/components/${project.artifactId}";


##########################################################################
sub Configure($$@) {
##########################################################################
    
  my ( $self, $config) = @_;
  
  my $this_host_name = hostname();
  my $this_host_domain = hostdomain();
  my $this_host_full = join ".", $this_host_name, $this_host_domain;

  my $xrootd_config = $config->getElement(PANPATH)->getTree();
  my $xrootd_options = $xrootd_config->{options};

  # Process separatly DPM and LFC configuration
  
  my $comp_max_servers;

  # Check that current node is part of the configuration

  if ( ! exists($xrootd_config->{hosts}->{$this_host_full}) ) {
    $self->error("Local host ($this_host_full) is not part of the xrootd configuration");
    return(2);
  }

  # General initializations
  my $xrootd_install_root;
  if ( defined($xrootd_options->{installDir}) ) {
    $xrootd_install_root = $xrootd_options->{installDir};
  } else {
    $xrootd_install_root = XROOTD_INSTALL_ROOT_DEFAULT;    
  }
  if ( $xrootd_install_root == '/' ) {
    $xrootd_install_root = "";
  }
  my $xrootd_bin_dir = $xrootd_install_root . '/usr/bin';

  my $xrootd_config_dir = $xrootd_options->{configDir};
  unless ( $xrootd_config_dir =~ /^\s*\// ) {
    $xrootd_config_dir = $xrootd_install_root . '/etc/' . $xrootd_config_dir;
  }
  if ( defined($xrootd_options->{config}) ) {
    my $xrootd_options_file = $xrootd_options->{config};
    unless ( $xrootd_options_file =~ /^\s*\// ) {
      $xrootd_options_file = $xrootd_install_root . '/etc/' . $xrootd_options->{config};
    }
  }


  # Update configuration file for each role (Xrootd instance) held by the local node.
  my $roles = $xrootd_config->{hosts}->{$this_host_full}->{roles};
  if ( defined($xrootd_options->{xrootdInstances}) ) {    
    while ( my ($instance,$params) = each(%{$xrootd_options->{xrootdInstances}}) ) {
      my $instance_type = $params->{type};
      if ( grep(/^$instance_type$/,@$roles) ) {
        $self->info("Checking xrootd instance '$instance' configuration ($params->{configFile})...");
        my $changes = $self->updateConfigFile($params->{configFile},$config_rules{$instance_type},$xrootd_options);
        if ( $changes > 0 ) {
          $self->serviceRestartNeeded('xrootd');
        } elsif ( $changes < 0 ) {
          $self->error("Error updating xrootd configuration for instance $instance_type (".$params->{configFile}.")");
        }
      }
    }
  }
  # CMSD instances must all be instanciated on a federated redirector
  my $instance_type = "fedredir";
  if ( grep(/^$instance_type$/,@$roles) ) {
    if ( defined($xrootd_options->{cmsdInstances}) ) {
      while ( my ($instance,$params) = each(%{$xrootd_options->{cmsdInstances}}) ) {
        $self->info("Checking cmsd instance '$instance' configuration ($params->{configFile})...");
        my $changes = $self->updateConfigFile($params->{configFile},$config_rules{$instance_type},$xrootd_options);
        if ( $changes > 0 ) {
          $self->serviceRestartNeeded('cmsd');
        } elsif ( $changes < 0 ) {
          $self->error("Error updating xrootd configuration for instance $instance_type (".$params->{configFile}.")");
        }  
      }  
    } else {
      $self->warn("Current host is a fedredir but has no CMSD instances configured");
    }
  }    
  
    
  # Build Authz configuration file for token-based authz
  if ( exists($xrootd_options->{tokenAuthz}) ) {
    # Build authz.cf
    my $token_auth_conf = $xrootd_options->{tokenAuthz};
    $self->info("Token-based authorization used: checking its configuration...");
    my $exported_vo_path_root = $token_auth_conf->{exportedPathRoot};
    my $xrootd_authz_conf_file = $token_auth_conf->{authzConf};
    unless ( $xrootd_authz_conf_file =~ /^\s*\// ) {
      $xrootd_authz_conf_file = $xrootd_config_dir . "/" . $xrootd_authz_conf_file;
    };
    $self->debug(1,"Authorization configuration file:".$token_auth_conf->{authzConf});
    my $xrootd_token_priv_key;
    if ( defined($token_auth_conf->{tokenPrivateKey}) ) {
      $xrootd_token_priv_key = $token_auth_conf->{tokenPrivateKey};
    } else {
      $xrootd_token_priv_key = $xrootd_config_dir . '/pvkey.pem';    
    }
    my $xrootd_token_pub_key;
    if ( defined($token_auth_conf->{tokenPublicKey}) ) {
      $xrootd_token_pub_key = $token_auth_conf->{tokenPublicKey};
    } else {
      $xrootd_token_pub_key = $xrootd_config_dir . '/pvkey.pem';    
    }
    
    $self->debug(1,"Opening token authz configuration file ($xrootd_authz_conf_file)");
    my $fh = CAF::FileWriter->new($xrootd_authz_conf_file,
                                  backup => BACKUP_FILE_EXT,
                                  owner => $xrootd_options->{daemonUser},
                                  group => $xrootd_options->{daemonGroup},
                                  mode => 0400,
                                  log => $self,
                                 );
    print $fh "Configuration file for xroot authz generated by quattor - DO NOT EDIT.\n\n" .
              "# Keys reside in ".$xrootd_config_dir."\n" .
              "KEY VO:*       PRIVKEY:".$xrootd_token_priv_key." PUBKEY:".$xrootd_token_pub_key."\n\n" .
              "# Restrict the name space exported\n";
    if ( $token_auth_conf->{exportedVOs} ) {
      while ( my ($vo, $params) = each(%{$token_auth_conf->{exportedVOs}}) ) {
        my $exported_full_path;      
        if ( exists($params->{'path'}) ) {
          my $exported_path = $params->{'path'};
          if ( $exported_path =~ /^\// ) {
            $exported_full_path = $exported_path;               
          } else {
            $exported_full_path = $exported_vo_path_root.'/'.$exported_path;   
          }
        } else {  
          $exported_full_path = $exported_vo_path_root.'/'.$vo;      
        }
        print $fh "EXPORT PATH:".$exported_full_path." VO:".$vo."     ACCESS:ALLOW CERT:*\n";
      }
    } else {
      $self->warn("dpm-xroot: export enabled for all VOs. You should consider restrict to one VO only.");
      print $fh "EXPORT PATH:".$exported_vo_path_root." VO:*     ACCESS:ALLOW CERT:*\n";
    } 
  
    print $fh "\n# Define operations requiring authorization.\n";
    print $fh "# NOAUTHZ operations honour authentication if present but don't require it.\n";
    if ( $token_auth_conf->{accessRules} ) {
      for my $rule (@{$token_auth_conf->{accessRules}}) {
        my $auth_ops = join '|', @{$rule->{authenticated}};
        my $noauth_ops = join '|', @{$rule->{unauthenticated}};
        print $fh "RULE PATH:".$rule->{path}.
                  " AUTHZ:$auth_ops| NOAUTHZ:$noauth_ops| VO:".$rule->{vo}." CERT:".$rule->{cert}."\n";
      }
    } else {
      print $fh "\n# WARNING: no access rules defined in quattor configuration.\n";
    }

    my $changes = $fh->close();
    if ( $changes > 0 ) {
      $self->serviceRestartNeeded('xrootd');
    } elsif ( $changes < 0 ) {
      $self->error("Error updating xrootd authorization configuration ($xrootd_authz_conf_file)");
    }
  
    # Set right permissions on token public/private keys
    for my $key ($xrootd_token_priv_key,$xrootd_token_pub_key) {
      if ( -f $key ) {
        $self->debug(1,"Checking permission on $key");
        $changes = LC::Check::status($key,
                                     owner => $xrootd_options->{daemonUser},
                                     group => $xrootd_options->{daemonGroup},
                                     mode => 0400,
                                    );
        unless ( defined($changes) ) {
          $self->error("Error setting permissions on xrootd token key $key");
        }
      } else {
          $self->warn("xrootd token key $key not found.");
      }  
    }
  } else {
    $self->debug(1,"Token-based authentication disabled.");
  }
  
  
  # DPM/Xrootd sysconfig file if enabled
  if ( defined($xrootd_options->{dpm}) ) {
    $self->info("Checking DPM/Xrootd plugin configuration ($xrootd_sysconfig_file)...");
    my $changes = $self->updateConfigFile($xrootd_sysconfig_file,\%xrootd_sysconfig_rules,$xrootd_options);
    if ( $changes > 0 ) {
      $self->serviceRestartNeeded('xrootd,cmsd');
    } elsif ( $changes < 0 ) {
      $self->error("Error updating xrootd sysconfig file ($xrootd_sysconfig_file)");
    }
  } else {
    $self->debug(1,"DPM/Xrootd plugin disabled.");
  }


  # Restart services.
  # Don't signal error as it has already been signaled by restartServices().
  if ( $xrootd_options->{restartServices}  && $self->restartServices() ) {
    return(1);
  }


  return 0;
}


# Function to add a service in the list of services needed to be restarted.
# Services can be a comma separated list.
# It is valid to pass a role with no associated services (nothing done).
#
# Arguments :
#  roles : roles the associated services need to be restarted (comma separated list)
sub serviceRestartNeeded () {
  my $function_name = "serviceRestartNeeded";
  my $self = shift;

  my $roles = shift;
  unless ( $roles ) {
    $self->error("$function_name: 'roles' argument missing");
    return 0;
  }

  my $list;
  unless ( $list = $self->getServiceRestartList() ) {
    $self->debug(1,"$function_name: Creating list of service needed to be restarted");
    $self->{SERVICERESTARTLIST} = {};
    $list = $self->getServiceRestartList();
  }

  my @roles = split /\s*,\s*/, $roles;
  for my $role (@roles) {
    my @services = split /\s*,\s*/, $xrootd_services{$role};
    foreach my $service (@services) {      
      unless ( exists(${$list}{$service}) ) {
        $self->debug(1,"$function_name: adding '$service' to the list of service needed to be restarted");
        ${$list}{$service} = "";
      }
    }
  }

  $self->debug(2,"$function_name: restart list = '".join(" ",keys(%{$list}))."'");
}


# Return list of services needed to be restarted
sub getServiceRestartList () {
  my $function_name = "getServiceRestartList";
  my $self = shift;

  if ( defined($self->{SERVICERESTARTLIST}) ) {
    $self->debug(2,"$function_name: restart list = ".join(" ",keys(%{$self->{SERVICERESTARTLIST}})));
    return $self->{SERVICERESTARTLIST};
  } else {
    $self->debug(2,"$function_name: list doesn't exist");
    return undef
  }

}


# Restart services needed to be restarted
# Returns 0 if all services have been restarted successfully, else
# the number of services which failed to restart.

sub restartServices () {
  my $function_name = "RestartServices";
  my $self = shift;
  my $global_status = 0;
  
  $self->debug(1,"$function_name: restarting services affected by configuration changes");

  # Need to do stop+start as sometimes dpm daemon doesn't restart properly with
  # 'restart'. Try to restart even if stop failed (can be just the daemon is 
  # already stopped)
  if ( my $list = $self->getServiceRestartList() ) {
    $self->debug(1,"$function_name: list of services to restart : ".join(" ",keys(%{$list})));
    for my $service (keys %{$list}) {
      $self->info("Restarting service $service");
      CAF::Process->new([SERVICECMD, $service, "stop"],log=>$self)->run();
      if ( $? ) {
        # Service can be stopped, don't consider failure to stop as an error
        $self->warn("\tFailed to stop $service");
      }
      sleep 5;    # Give time to the daemon to shut down
      my $attempt = 5;
      my $status;
      my $command = CAF::Process->new([SERVICECMD, $service, "start"],log=>$self);
      $command->run();
      $status = $?;
      while ( $attempt && $status ) {
        $self->debug(1,"$function_name: $service startup failed (probably not shutdown yet). Retrying ($attempt attempts remaining)");
        sleep 5;
        $attempt--;
        $command->run();
        $status = $?;
      }
      if ( $status ) {
        $global_status++;
        $self->error("\tFailed to start $service");
      } else {
        $self->info("Service $service restarted successfully");
      }
    }
  }

  return($global_status);
}


# This function formats an attribute value based on the value format specified.
#
# Arguments :
#        attr_value : attribue value
#        line_fmt : line format (see LINE_FORMAT_xxx constants)
#        value_fmt : value format (see LINE_VALUE_xxx constants)
sub formatAttributeValue () {
  my $function_name = "formatAttributeValue";
  my $self = shift;

  my $attr_value = shift;
  unless ( $attr_value ) {
    $self->error("$function_name: 'attr_value' argument missing");
    return 1;
  }
  my $line_fmt = shift;
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'list_fmt' argument missing");
    return 1;
  }
  my $value_fmt = shift;
  unless ( defined($value_fmt) ) {
    $self->error("$function_name: 'value_fmt' argument missing");
    return 1;
  }

  $self->debug(2,"$function_name: formatting attribute value >>>$attr_value<<< (line fmt=$line_fmt, value fmt=$value_fmt)");

  my $formatted_value;
  if ( $value_fmt == LINE_VALUE_HOST_LIST ) {    
    # Duplicates may exist as result of a join. Checkt it.
    my @hosts = split /\s+/, $attr_value;
    my %hosts;
    for my $host (@hosts) {
      unless ( exists($hosts{$host}) ) {
        $hosts{$host} = "";
      }
    }  
    my $formatted_value="";
    for my $host (sort keys %hosts) {
      $formatted_value .= "$host ";
    }  
    # Some config files are sensitive to extra spaces : suppress trailing spaces
    $formatted_value =~ s/\s+$//;
    $self->debug(1,"Formatted hosts list : >>$formatted_value<<");

  } elsif ( $value_fmt == LINE_VALUE_BOOLEAN ) {
    if ( $attr_value ) {
      $formatted_value = '"yes"';
    } else {
      $formatted_value = '"no"';
    }

  } elsif ( $value_fmt == LINE_VALUE_INSTANCE_PARAMS ) {
    # Instance parameters are described in a nlist
    if ( exists($attr_value->{logFile}) ) {
      $formatted_value .= " -l $attr_value->{logFile}";
    }
    if ( exists($attr_value->{configFile}) ) {
      $formatted_value .= " -c $attr_value->{configFile}";
    }
    
  } elsif ( $value_fmt == LINE_VALUE_ARRAY ) {
    $formatted_value = join " ", @$attr_value;

  } elsif ( $value_fmt == LINE_VALUE_HASH_KEYS ) {
    $formatted_value = join " ", keys(%$attr_value);
    
  } elsif ( ($value_fmt == LINE_VALUE_AS_IS) || ($value_fmt == LINE_VALUE_STRING_HASH) ) {
    $formatted_value = $attr_value;
    
  } else {
    $self->error("$function_name: invalid value format ($value_fmt) (internal error)")    
  }

  # Quote value if necessary
  if ( ($line_fmt == LINE_FORMAT_PARAM) || ($line_fmt == LINE_FORMAT_ENVVAR) ) {
    if ( $formatted_value =~ /\s+/ ) {
      $self->debug(2,"$function_name: quoting value '$formatted_value'");
      $formatted_value = '"' . $formatted_value . '"';
    }
  }
  
  $self->debug(2,"$function_name: formatted value >>>$formatted_value<<<");
  return $formatted_value;
}


# This function formats a configuration line using keyword and value,
# according to the line format requested. Values containing spaces are
# quoted if the line format is not LINE_FORMAT_XRDCFG.
#
# Arguments :
#        keyword : line keyword
#        value : keyword value (can be empty)
#        line_fmt : line format (see LINE_FORMAT_xxx constants)
sub formatConfigLine () {
  my $function_name = "formatConfigLine";
  my $self = shift;

  my $keyword = shift;
  unless ( $keyword ) {
    $self->error("$function_name: 'keyword' argument missing");
    return 1;
  }
  my $value = shift;
  unless ( defined($value) ) {
    $self->error("$function_name: 'value' argument missing");
    return 1;
  }
  my $line_fmt = shift;
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing");
    return 1;
  }

  my $config_line = "";

  if ( $line_fmt == LINE_FORMAT_PARAM ) {
    $config_line = "$keyword=$value";
  } elsif ( $line_fmt == LINE_FORMAT_ENVVAR ) {
    $config_line = "export $keyword=$value";
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SETENV ) {
    $config_line = "setenv $keyword = $value";
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SETENV ) {
    $config_line = "set $keyword = $value";
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG ) {
    $config_line = $keyword;
    $config_line .= " $value" if $value;
    # In trust (shift.conf) format, there should be only one blank between
    # tokens and no trailing spaces.
    $config_line =~ s/\s\s+/ /g;
    $config_line =~ s/\s+$//;
  } else {
    $self->error("$function_name: invalid line format ($line_fmt). Internal inconsistency.");
  }

  $self->debug(2,"$function_name: Configuration line : >>$config_line<<");
  return $config_line;
}


# This function builds a pattern that will match an existing configuration line for
# the configuration parameter specified. The pattern built takes into account the line format.
# Every whitespace in the pattern (configuration parameter) are replaced by \s+.
# If the line format is LINE_FORMAT_XRDCFG, no whitespace is
# imposed at the end of the pattern, as these format can be used to write a configuration
# directive as a keyword with no value.
#
# Arguments :
#   config_param: parameter to update
#   line_fmt: line format (see LINE_FORMAT_xxx constants)
#   config_value: when defined, make it part of the pattern (used when multiple lines
#                 with the same keyword are allowed)
sub buildLinePattern () {
  my $function_name = "buildLinePattern";
  my $self = shift;

  my $config_param = shift;
  unless ( $config_param ) {
    $self->error("$function_name: 'config_param' argument missing");
    return undef;
  }
  my $line_fmt = shift;
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing");
    return undef;
  }
  my $config_value = shift;
  if ( $config_value ) {
    $self->debug(2,"$function_name: configuration value '$config_value' will be added to the pattern");
    $config_value =~ s/\s+/\\s+/g;
    $config_value =~ s/\-/\\-/g;
    $config_value =~ s/\./\\./g;
    $config_value =~ s/\[/\\[/g;
    $config_value =~ s/\(/\\[/g;
  } else {
    $config_value = "";
  }

  $config_param =~ s/\s+/\\s+/g;
  my $config_param_pattern;
  if ( $line_fmt == LINE_FORMAT_PARAM ) {
    $config_param_pattern = "#?\\s*$config_param=".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_ENVVAR ) {
    $config_param_pattern = "#?\\s*export $config_param=".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SETENV ) {
    $config_param_pattern = "#?\\s*setenv\\s+$config_param\\s*=\\s*".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG_SET ) {
    $config_param_pattern = "#?\\s*set\\s+$config_param\\s*=\\s*".$config_value;
  } elsif ( $line_fmt == LINE_FORMAT_XRDCFG ) {
    $config_param_pattern = "#?\\s*$config_param";
    # Avoid adding a withespace requirement if there is no config_value
    if ( $config_value ne "" ) {
      $config_param_pattern .= "\\s+" . $config_value;
    }
  } else {
    $self->error("$function_name: invalid line format ($line_fmt). Internal inconsistency.");
    return undef;
  }

  return $config_param_pattern
}


# This function comments out a configuration line matching the configuration parameter.
# Match operation takes into account the line format.
#
# Arguments :
#        fh : a FileEditor object
#        config_param: parameter to update
#        line_fmt : line format (see LINE_FORMAT_xxx constants)
sub removeConfigLine () {
  my $function_name = "removeConfigLine";
  my $self = shift;

  my $fh = shift;
  unless ( $fh ) {
    $self->error("$function_name: 'fh' argument missing");
    return 1;
  }
  my $config_param = shift;
  unless ( $config_param ) {
    $self->error("$function_name: 'config_param' argument missing");
    return 1;
  }
  my $line_fmt = shift;
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing");
    return 1;
  }

  # Build a pattern to look for.
  # In addition to the pattern, impose the present of the standard comment added by Quattor
  # to ensure that the line was previously managed by Quattor, except for LINE_FORMAT_XRDCFG line format.
  my $config_param_pattern = $self->buildLinePattern($config_param,$line_fmt);
    if ( ($line_fmt == LINE_FORMAT_PARAM) || ($line_fmt == LINE_FORMAT_ENVVAR) ) {
    my $comment = LINE_QUATTOR_COMMENT;
    $comment =~ s/\s+/\\s+/g;
    $config_param_pattern .= '.*' . $comment . '\\s*$';
  }

  $self->debug(1,"$function_name: commenting out lines matching pattern >>>".$config_param_pattern."<<<");
  # All matching lines must be commented out, except if they are already commented out.
  # The code used is a customized version of FileEditor::replace() that lacks backreferences.
  my @lns;
  seek($fh, 0, SEEK_SET);
  while (my $l = <$fh>) {
    if ($l =~ qr/^$config_param_pattern/ && $l !~ qr/^\s*#/) {
        $self->debug(2,"$function_name: commenting out matching line >>>".$l."<<<");
        push (@lns, '#'.$l);
    } else {
        push (@lns, $l);
    }
  }
  $fh->set_contents (join("", @lns));
 
}


# This function do the actual update of a configuration line after doing the final
# line formatting based on the line format.
#
# Arguments :
#        fh : a FileEditor object
#        config_param: parameter to update
#        config_value : parameter value (can be empty)
#        line_fmt : line format (see LINE_FORMAT_xxx constants)
#        multiple : if true, multiple lines with the same keyword can exist (D: false)
sub updateConfigLine () {
  my $function_name = "updateConfigLine";
  my $self = shift;

  my $fh = shift;
  unless ( $fh ) {
    $self->error("$function_name: 'fh' argument missing");
    return 1;
  }
  my $config_param = shift;
  unless ( $config_param ) {
    $self->error("$function_name: 'config_param' argument missing");
    return 1;
  }
  my $config_value = shift;
  unless ( defined($config_value) ) {
    $self->error("$function_name: 'config_value' argument missing");
    return 1;
  }
  my $line_fmt = shift;
  unless ( defined($line_fmt) ) {
    $self->error("$function_name: 'line_fmt' argument missing");
    return 1;
  }
  my $multiple = shift;
  unless ( defined($multiple) ) {
    $multiple = 0;
  }

  my $newline;
  my $config_param_pattern;
  $newline = $self->formatConfigLine($config_param,$config_value,$line_fmt);

  # Build a pattern to look for.
  if ( $multiple ) {
    $self->debug(2,"$function_name: 'multiple' flag enabled");
    $config_param_pattern = $self->buildLinePattern($config_param,$line_fmt,$config_value);    
  } else {
    $config_param_pattern = $self->buildLinePattern($config_param,$line_fmt);
  }
  if ( ($line_fmt == LINE_FORMAT_XRDCFG) && !$multiple ) {
    if ( $config_value ) {
      $config_param_pattern .= "\\s+";    # If the value is defined in these formats, impose a whitespace at the end
    }
  }

  # Update the matching configuration lines
  if ( $newline ) {
    my $comment = "";
    if ( ($line_fmt == LINE_FORMAT_PARAM) || ($line_fmt == LINE_FORMAT_ENVVAR) ) {
      $comment = LINE_QUATTOR_COMMENT;
    }
    $self->debug(1,"$function_name: checking expected configuration line ($newline) with pattern >>>".$config_param_pattern."<<<");
    $fh->add_or_replace_lines(qr/^$config_param_pattern/,
                              qr/^$newline$/,
                              $newline.$comment."\n",
                              ENDING_OF_FILE,
                             );      
  }
}


# Update configuration file content,  applying configuration rules.
#
# Arguments :
#       file_name: name of the file to update
#       config_rules: config rules corresponding to the file to build
#       config_options: configuration parameters used to build actual configuration

sub updateConfigFile () {
  my $function_name = "updateConfigFile";
  my $self = shift;

  my $file_name = shift;
  unless ( $file_name ) {
    $self->error("$function_name: 'file_name' argument missing");
    return 1;
  }
  my $config_rules = shift;
  unless ( $config_rules ) {
    $self->error("$function_name: 'config_rules' argument missing");
    return 1;
  }
  my $config_options = shift;
  unless ( $config_options ) {
    $self->error("$function_name: 'config_options' argument missing");
    return 1;
  }

  my $fh = CAF::FileEditor->new($file_name,
                                backup => BACKUP_FILE_EXT,
                                log => $self);
  seek($fh, 0, SEEK_SET);

  # Check that config file has an appropriate header
  my $intro_pattern = "# This file is managed by Quattor";
  my $intro = "# This file is managed by Quattor - DO NOT EDIT lines generated by Quattor";
  $fh->add_or_replace_lines(qr/^$intro_pattern/,
                            qr/^$intro$/,
                            $intro."\n#\n",
                            BEGINNING_OF_FILE,
                           );
  
  # Loop over all config rule entries.
  # Config rules are stored in a hash whose key is the variable to write
  # and whose value is the rule itself.
  # Each rule format is '[condition->]attribute:option_set[,option_set,...];line_fmt' where
  #     condition: reserved for future use
  #     option_set and attribute: attribute in option set that must be substituted
  #     line_fmt: the format to use when building the line
  # An empty rule is valid and means that the keyword part must be
  # written as is, using the line_fmt specified.
  
  my $rule_id = 0;
  while ( my ($keyword,$rule) = each(%{$config_rules}) ) {
    $rule_id++;

    # Split different elements of the rule
    ($rule, my $line_fmt, my $value_fmt) = split /;/, $rule;
    unless ( $line_fmt ) {
      $line_fmt = LINE_FORMAT_DEFAULT;
    }
    unless ( $value_fmt ) {
      $value_fmt = LINE_VALUE_AS_IS;
    }

    (my $condition, my $tmp) = split /->/, $rule;
    if ( $tmp ) {
      $rule = $tmp;
    } else {
      $condition = "";
    }
    $self->debug(1,"$function_name: processing rule ".$rule_id."(variable=>>>".$keyword.
                      "<<<, condition=>>>".$condition."<<<, rule=>>>".$rule."<<<, fmt=".$line_fmt.")");

    unless ( $condition eq "" ) {
      $self->debug(1,"$function_name: checking condition >>>$condition<<<");
      my ($cond_attribute,$cond_option_set) = split /:/, $condition;
      unless ( $cond_option_set ) {
        $cond_option_set = $cond_attribute;
        $cond_attribute = "";
      }
      $self->debug(2,"$function_name: condition option set = '$cond_option_set', condition attribute = '$cond_attribute'");
      if ( $cond_attribute ) {
        # Due to an exists() flaw, testing directly exists($config_options->{$cond_option_set}->{$cond_attribute}) will spring
        # into existence $config_options->{$cond_option_set} if it doesn't exist.
        next unless exists($config_options->{$cond_option_set}) && exists($config_options->{$cond_option_set}->{$cond_attribute});
      } elsif ( $cond_option_set ) {
        next unless exists($config_options->{$cond_option_set});
      }
    }

    my @option_sets;
    (my $attribute, my $option_sets_str) = split /:/, $rule;
    if ( $option_sets_str ) {
      @option_sets = split /\s*,\s*/, $option_sets_str;
    }

    # Build the value to be substitued for each option set specified.
    # option_set=GLOBAL is a special case indicating a global option instead of an
    # attribute in a specific option set.
    my $config_value = "";
    my $attribute_present = 1;
    if ( $attribute ) {
      for my $option_set (@option_sets) {
        my $attr_value;
        if ( $option_set eq "GLOBAL" ) {
          if ( exists($config_options->{$attribute}) ) {
            $attr_value = $config_options->{$attribute};
          } else {
            $self->debug(1,"$function_name: attribute '$attribute' not found in global option set");
            $attribute_present = 0;
          }
        } else {
          # Due to an exists() flaw, testing directly exists($config_options->{$cond_option_set}->{$cond_attribute}) will spring
          # into existence $config_options->{$cond_option_set} if it doesn't exist.
          if ( exists($config_options->{$option_set}) && exists($config_options->{$option_set}->{$attribute}) ) {
            $attr_value = $config_options->{$option_set}->{$attribute};
          } else {
            $self->debug(1,"$function_name: attribute '$attribute' not found in option set '$option_set'");
            $attribute_present = 0;
          } 
        }

        # If attribute is not defined in the present configuration, check if there is a matching
        # line in the config file for the keyword and comment it out.
        # Note that this will never match instance parameters and will not remove entries
        # no longer part of the configuration in a still existing LINE_VALUE_ARRAY or
        # LINE_VALUE_STRING_HASH.
        unless ( $attribute_present ) {
          $self->removeConfigLine($fh,$keyword,$line_fmt);
          next;
        }
    
        # Instance parameters are specific, as this is a nlist of instance
        # with the value being a nlist of parameters for the instance.
        # Also the variable name must be updated to contain the instance name.
        # One configuration line must be written/updated for each instance.
        if ( $value_fmt == LINE_VALUE_INSTANCE_PARAMS ) {
          while ( my ($instance, $params) = each(%$attr_value) ) {
            $self->debug(1,"$function_name: formatting instance '$instance' parameters ($params)");
            $config_value = $self->formatAttributeValue($params,
                                                        $line_fmt,
                                                        $value_fmt,
                                                       );
            my $config_param = $keyword;
            my $instance_uc = uc($instance);
            $config_param =~ s/%%INSTANCE%%/$instance_uc/;
            $self->debug(2,"New variable name generated: >>>$config_param<<<");
            $self->updateConfigLine($fh,$config_param,$config_value,$line_fmt);
          }
        } elsif ( $value_fmt == LINE_VALUE_STRING_HASH ) {
          # With this value format, several lines with the same keyword are generated,
          # one for each key/value pair.
          while ( my ($k,$v) = each(%$attr_value) ) {
            # Value is made by joining key and value as a string
            # Keys may be escaped if they contain characters like '/': unescaping a non-escaped
            # string is generally harmless.
            my $tmp = unescape($k)." $v";
            $self->debug(1,"$function_name: formatting attribute '$attribute' value ($tmp, value_fmt=$value_fmt)");
            $config_value = $self->formatAttributeValue($tmp,
                                                        $line_fmt,
                                                        $value_fmt,
                                                       );
            $self->updateConfigLine($fh,$keyword,$config_value,$line_fmt,1);
          }
        } else {
          $self->debug(1,"$function_name: formatting attribute '$attribute' value ($attr_value, value_fmt=$value_fmt)");
          $config_value .= $self->formatAttributeValue($attr_value,
                                                       $line_fmt,
                                                       $value_fmt);
          $self->debug(2,"$function_name: adding attribute '".$attribute."' from option set '".$option_set.
                                                                "' to value (config_value=".$config_value.")");
        }
      }
    } else {
      # $attribute empty means an empty rule : in this case,just write the configuration param.
      $self->debug(1,"$function_name: no attribute specified in rule '$rule'");
    }

    # Instance parameters and string hashes have already been written
    if ( ($value_fmt != LINE_VALUE_INSTANCE_PARAMS) && ($value_fmt != LINE_VALUE_STRING_HASH) && $attribute_present ) {
      $self->updateConfigLine($fh,$keyword,$config_value,$line_fmt);
    }  
  }

  # Update configuration file if content has changed
  $self->debug(1,"$function_name: actually updating the file...");
  my $changes = $fh->close();

  return $changes;
}


1;      # Required for PERL modules
