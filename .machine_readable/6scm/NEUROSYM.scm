;; SPDX-License-Identifier: MPL-2.0
;; NEUROSYM.scm - Neurosymbolic integration config

(define neurosym-config
  `((version . "1.0.0")
    (symbolic-layer
      ((type . "scheme")
       (reasoning . "deductive")
       (verification . "type-based")))
    (neural-layer
      ((embeddings . false)
       (fine-tuning . false)))
    (integration . ())))
