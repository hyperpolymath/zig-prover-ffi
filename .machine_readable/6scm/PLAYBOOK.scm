;; SPDX-License-Identifier: MPL-2.0
;; PLAYBOOK.scm - Operational runbook

(define playbook
  `((version . "1.0.0")
    (procedures
      ((build . (("all" . "just build")))
       (test . (("unit" . "just test")))
       (release . (("check" . "just rsr-check")))))
    (alerts . ())
    (contacts . ())))
