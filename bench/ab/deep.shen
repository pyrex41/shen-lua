(define upto N M -> (if (> N M) [] [N | (upto (+ N 1) M)]))
(output "deep 10k: ~A~%" (trap-error (length (upto 1 10000)) (/. E -1)))
(output "deep 100k: ~A~%" (trap-error (length (upto 1 100000)) (/. E -1)))
(output "deep 1M: ~A~%" (trap-error (length (upto 1 1000000)) (/. E -1)))
