;;; GNU Guix --- Functional package management for GNU
;;; Copyright Â© 2022 Simon Streit <simon@netpanic.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu services samba)

  #:use-module (gnu packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages samba)

  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services base)
  #:use-module (gnu system shadow)

  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix modules)
  #:use-module (guix records)

  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)

  #:export (samba-service-type
            samba-configuration
            samba-smb-conf

            wsdd-service-type
            wsdd-configuration))

(define %smb-conf
  (plain-file "smb.conf" "[global]
    workgroup = WORKGROUP
    server string = Samba Server
    server role = standalone server
    log file = /var/log/samba/log.%m
    logging = file
"))

(define-record-type* <samba-configuration>
  samba-configuration
  make-samba-configuration
  samba-configuration?
  (package              samba-configuration-package
                        (default samba))
  (config-file          samba-configuration-config-file
                        (default #f))
  (enable-samba?        samba-configuration-enable-samba?
                        (default #f))
  (enable-smbd?         samba-configuration-enable-smbd?
                        (default #t))
  (enable-nmbd?         samba-configuration-enable-nmbd?
                        (default #t))
  (enable-winbindd?     samba-configuration-enable-winbindd?
                        (default #t)))

(define (samba-activation config)
  (let ((package (samba-configuration-package config))
        (config-file (samba-configuration-config-file config)))
    (with-imported-modules '((guix build utils))
      (let ((lib-dir "/var/lib/samba")
            (log-dir "/var/log/samba")
            (run-dir "/var/run/samba")
            (etc-dir "/etc/samba")
            (smb.conf "/etc/samba/smb.conf"))
        #~(begin
            (use-modules (guix build utils))
            (mkdir-p #$etc-dir)
            (mkdir-p #$lib-dir)
            (mkdir-p/perms (string-append #$lib-dir "/private")
                           (getpwnam "root") #o700)
            (mkdir-p #$log-dir)
            (mkdir-p #$run-dir)
            (copy-file #$config-file #$smb.conf)
            (invoke #$(file-append package "/bin/testparm")
                    "--suppress-prompt" #$smb.conf))))))

(define (samba-samba-shepherd-service config)
  (let ((package (samba-configuration-package config))
        (config-file (samba-configuration-config-file config)))
       (list (shepherd-service
              (documentation "Run Samba")
              (provision '(samba-samba))
              (requirement '(networking))
              (start #~(make-forkexec-constructor
                        (list #$(file-append package "/sbin/samba")
                              (string-append "--configfile=" #$config-file)
                              "--foreground"
                              "--no-process-group")))
              (stop #~(make-kill-destructor))))))

(define (samba-nmbd-shepherd-service config)
  (let ((package (samba-configuration-package config))
        (config-file (samba-configuration-config-file config)))
       (list (shepherd-service
              (documentation "Run NMBD")
              (provision '(samba-nmbd))
              (requirement '(networking))
              (start #~(make-forkexec-constructor
                        (list #$(file-append package "/sbin/nmbd")
                              (string-append "--configfile=" #$config-file)
                              "--foreground"
                              "--no-process-group")))
              (stop #~(make-kill-destructor))))))

(define (samba-smbd-shepherd-service config)
  (let ((package (samba-configuration-package config))
        (config-file (samba-configuration-config-file config)))
       (list (shepherd-service
              (documentation "Run SMBD")
              (provision '(samba-smbd))
              (requirement '(networking))
              (start #~(make-forkexec-constructor
                        (list #$(file-append package "/sbin/smbd")
                              (string-append "--configfile=" #$config-file)
                              "--foreground"
                              "--no-process-group")))
              (stop #~(make-kill-destructor))))))

(define (samba-winbindd-shepherd-service config)
  (let ((package (samba-configuration-package config))
        (config-file (samba-configuration-config-file config)))
       (list (shepherd-service
              (documentation "Run Winnbindd for Name Service Switch")
              (provision '(samba-winbindd))
              (requirement '(networking))
              (start #~(make-forkexec-constructor
                        (list #$(file-append package "/sbin/winbindd")
                              (string-append "--configfile=" #$config-file)
                              "--foreground"
                              "--no-process-group")))
              (stop #~(make-kill-destructor))))))

(define (samba-shepherd-services config)
  (append (if (samba-configuration-enable-samba? config)
              (samba-samba-shepherd-service config)
              '())
          (if (samba-configuration-enable-nmbd? config)
              (samba-nmbd-shepherd-service config)
              '())
          (if (samba-configuration-enable-smbd? config)
              (samba-smbd-shepherd-service config)
              '())
          (if (samba-configuration-enable-winbindd? config)
              (samba-winbindd-shepherd-service config)
              '())))

(define samba-service-type
  (service-type
   (name 'samba)
   (description "Samba")
   (extensions
    (list (service-extension shepherd-root-service-type
                             samba-shepherd-services)
          (service-extension activation-service-type
                             samba-activation)
          (service-extension profile-service-type
                             (compose list samba-configuration-package))))
   (default-value (samba-configuration))))


;;;
;;; WSDD
;;;

(define-record-type* <wsdd-configuration>
  wsdd-configuration
  make-wsdd-configuration
  wsdd-configuration?
  (package        wsdd-configuration-package
                  (default wsdd))
  (ipv4only?      wsdd-configuration-ipv4only?
                  (default #f))
  (ipv6only?      wsdd-configuration-ipv6only?
                  (default #f))
  (chroot         wsdd-configuration-chroot
                  (default #f))
  (hoplimit       wsdd-configuration-hoplimit
                  (default 1))
  (interfaces     wsdd-configuration-interfaces
                  (default '()))
  (uuid-device    wsdd-configuration-uuid-device
                  (default #f))
  (domain         wsdd-configuration-domain
                  (default #f))
  (hostname       wsdd-configuration-hostname
                  (default #f))
  (preserve-case? wsdd-configuration-preserve-case?
                  (default #f))
  (workgroup      wsdd-configuration-workgroup
                  (default "WORKGROUP")))

(define wsdd-accounts
  (list
   (user-group (name "wsdd"))
   (user-account (name "wsdd")
                 (group "wsdd")
                 (comment "Web Service Discovery user")
                 (home-directory "/var/empty")
                 (shell (file-append shadow "/sbin/nologin")))))

(define wsdd-shepherd-service
  (match-lambda
    (($ <wsdd-configuration> package ipv4only? ipv6only? chroot hoplimit
                             interfaces uuid-device domain hostname
                             preserve-case? workgroup)
     (list (shepherd-service
            (documentation "Run a Web Service Discovery service")
            (provision '(wsdd))
            (requirement '(networking))
            (start #~(make-forkexec-constructor
                      (list #$(file-append package "/bin/wsdd")
                            #$@(if ipv4only?
                                   #~("--ipv4only")
                                   '())
                            #$@(if ipv6only?
                                   #~("--ipv6only")
                                   '())
                            #$@(if chroot
                                   #~("--chroot" #$chroot)
                                   '())
                            #$@(if hoplimit
                                   #~("--hoplimit" #$(number->string hoplimit))
                                   '())
                            #$@(map (lambda (interfaces)
                                      (string-append "--interface=" interfaces))
                                    interfaces)
                            #$@(if uuid-device
                                   #~("--uuid" #$uuid-device)
                                   '())
                            #$@(if domain
                                   #~("--domain" #$domain)
                                   '())
                            #$@(if hostname
                                   #~("--hostname" #$hostname)
                                   '())
                            #$@(if preserve-case?
                                   #~("--preserve-case")
                                   '())
                            #$@(if workgroup
                                   #~("--workgroup" #$workgroup)
                                   '()))
                      #:user "wsdd"
                      #:group "wsdd"
                      #:log-file "/var/log/wsdd.log"))
            (stop #~(make-kill-destructor)))))))

(define wsdd-service-type
  (service-type
   (name 'wsdd)
   (description "Web Service Discovery Daemon")
   (extensions
    (list (service-extension shepherd-root-service-type
                             wsdd-shepherd-service)
          (service-extension account-service-type
                             (const wsdd-accounts))
          (service-extension profile-service-type
                             (compose list wsdd-configuration-package))))
   (default-value (wsdd-configuration))))
