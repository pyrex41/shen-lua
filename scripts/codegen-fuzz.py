#!/usr/bin/env python3
# Writes the deterministic program test/fixtures/codegen-fuzz-112.shen: scripts/codegen-fuzz.py 112 100
import random,sys
seed=int(sys.argv[1]); nf=int(sys.argv[2]) if len(sys.argv)>2 else 120
r=random.Random(seed)
POOL=['[[[1 2] [3 4]] [[5] 6] 7 8]','[[[1 2] [3 4]] [[5] 6] 7 8]','[[1 [2 [3 [4]]]] 5]','0','1','2.5','"s"','a','[]','[1]','[1 2]','[[1] 2]','[[1 2] [3]]','[a | b]','[[[1]] | c]','true','false']
class G:
    def __init__(s,vars,fname=None): s.vars=list(vars); s.fname=fname; s.n=0
    def fresh(s):
        s.n+=1; return 'V%d'%s.n
    def atom(s):
        c=r.random()
        if c<0.6 and s.vars: return r.choice(s.vars)
        return r.choice(POOL[:9]+['1','a'])
    def chain(s):
        e=r.choice(s.vars) if s.vars else '[1 2]'
        for _ in range(r.randint(0,3)):
            e='(%s %s)'%(r.choice(['hd','tl']),e)
        return e
    def b(s,d):
        if d<=0: return r.choice(['true','false','(cons? %s)'%s.chain()])
        c=r.randint(0,11)
        if c<=3: return '(cons? %s)'%s.chain()
        if c==4: return '(and %s %s)'%(s.b(d-1),s.b(d-1))
        if c==5: return '(or %s %s)'%(s.b(d-1),s.b(d-1))
        if c==6: return '(not %s)'%s.b(d-1)
        if c==7: return '(= %s %s)'%(s.v(d-1),s.v(d-1))
        if c==8: return '(if %s %s %s)'%(s.b(d-1),s.b(d-1),s.b(d-1))
        if c==9: return '(number? %s)'%s.v(d-1)
        if c==10: return '(> (pl %s) %s)'%(s.v(d-1),r.choice(['0','1']))
        return '(let %s %s %s)'%s.letb(d,lambda:s.b(d-1))
    def letb(s,d,k):
        v=r.choice(s.vars) if s.vars and r.random()<0.3 else s.fresh()
        val=s.v(d-1)
        add=v not in s.vars
        if add: s.vars.append(v)
        body=k()
        if add: s.vars.remove(v)
        return (v,val,body)
    def lam(s,n,d):
        vs=[r.choice(s.vars) if s.vars and r.random()<0.2 else s.fresh() for _ in range(n)]
        added=[v for v in vs if v not in s.vars]
        s.vars.extend(added)
        body=s.v(d-1)
        for v in set(added): s.vars.remove(v)
        return '(/. %s %s)'%(' '.join(vs),body)
    def v(s,d):
        if d<=0: return s.chain() if r.random()<0.5 else s.atom()
        c=r.randint(0,21)
        if c<=2: return s.chain()
        if c==3: return '[%s | %s]'%(s.v(d-1),s.v(d-1))
        if c<=6: return '(if %s %s %s)'%(s.b(d-1),s.v(d-1),s.v(d-1))
        if c==7:
            cl=' '.join('(%s %s)'%(s.b(d-1),s.v(d-1)) for _ in range(r.randint(1,3)))
            if r.random()<0.7: cl+=' (true %s)'%s.v(d-1)
            return '(cond %s)'%cl
        if c==8: return '(let %s %s %s)'%s.letb(d,lambda:s.v(d-1))
        if c==9: return '(tr %s %s)'%(r.randint(0,9),s.v(d-1))
        if c==10: return '(do (tr %s 0) %s)'%(r.randint(0,9),s.v(d-1))
        if c==11: return '(trap-error %s (/. E (cn "E:" (error-to-string E))))'%s.v(d-1)
        if c==12: return '(thaw (freeze %s))'%s.v(d-1)
        if c==13: # apply lambda directly, group sizes
            n=r.randint(1,5); m=r.randint(0,n+1)
            args=' '.join(s.v(d-1) for _ in range(m))
            return '(%s %s)'%(s.lam(n,d),args) if m else '(%s)'%s.lam(n,d)
        if c==14: # bound function
            n=r.randint(1,4); F=s.fresh(); l=s.lam(n,d); m=r.randint(1,n+1)
            args=' '.join(s.v(d-1) for _ in range(m))
            return '(let %s %s (%s %s))'%(F,l,F,args)
        if c==15:
            F=s.fresh(); g=r.choice(['two','three','one','curry2','(two 1)','(three 1 2)','(fn two)','undefinedf','7']); m=r.randint(1,4)
            args=' '.join(s.v(d-1) for _ in range(m))
            return '(let %s %s (%s %s))'%(F,g,F,args)
        if c==16 and s.fname:
            return '(if (> N 0) (%s (- N 1) %s %s) %s)'%(s.fname,s.v(d-1),s.v(d-1),s.v(d-1))
        if c==17 and s.fname:
            return '(if (> N 0) (cons %s (%s (- N 1) %s %s)) %s)'%(s.v(d-1),s.fname,s.v(d-1),s.v(d-1),s.v(d-1))
        if c==18 and s.fname:
            return '(if (> N 0) (%s (- N 1) %s (/. %s %s)) %s)'%(s.fname,s.v(d-1),'Q',s.v(d-1),s.v(d-1))
        if c==19: return '(two %s %s)'%(s.v(d-1),s.v(d-1))
        if c==20: return '(and %s %s)'%(s.b(d-1),s.b(d-1))
        if c==21: return '(or %s %s)'%(s.b(d-1),s.b(d-1))
        return s.atom()
print('''(set trace [])
(define tr K V -> (do (set trace [K | (value trace)]) V))
(define pl X -> (if (number? X) X 0))
(define two A B -> [two A B])
(define three A B C -> [three A B C])
(define one A -> [one A])
(define curry2 A -> (/. B [curry2 A B]))
(define nz V -> (if (= (shen.fnp V) true) fun (if (cons? V) (cons (nz (hd V)) (nz (tl V))) V)))
(define shen.fnp V -> (let S (str-any V) (and (>= (length (explode S)) 5) (= (hdn S 5) "funex"))))
(define hdn S 0 -> "" S N -> (cn (hdstr S) (hdn (tlstr S) (- N 1))))
(define str-any V -> (trap-error (make-string "~S" V) (/. E "err")))
(define go Id F -> (do (set trace []) (let R (trap-error (nz (thaw F)) (/. E (cn "ERR " (error-to-string E)))) (output "~A ~S ~S~%" Id R (value trace)))))
''')
inp=[('0',a,b) for a in POOL[:0]]
for i in range(nf):
    fn='f%d'%i
    style=r.randint(0,3)
    g=G(['X','Y','N'] if style!=3 else ['X','Y'], fn if style!=3 else None)
    d=r.randint(2,5)
    if style==0:
        print('(define %s N X Y -> %s)'%(fn,g.v(d)))
    elif style==1:
        g2=G(['H','T','Y','N'],fn)
        print('(define %s N [H | T] Y -> %s\n  N X Y -> %s)'%(fn,g2.v(d),g.v(d)))
    elif style==2:
        g2=G(['A','B','C','Y','N'],fn)
        print('(define %s N [[A | B] C] Y -> %s\n  N X [A | B] -> %s\n  N X Y -> %s)'%(fn,g2.v(d),G(['X','A','B','N'],fn).v(d),g.v(d)))
    for k in range(5):
        a,b=r.choice(POOL),r.choice(POOL)
        if style==3:
            print('(go t%d_%d (freeze (let X %s (let Y %s %s))))'%(i,k,a,b,g.v(d)))
        else:
            print('(go t%d_%d (freeze (%s %d %s %s)))'%(i,k,fn,r.randint(0,3),a,b))
