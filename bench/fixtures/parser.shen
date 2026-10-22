(defcc <sent>
 {(list symbol) ==> (list symbol)}
<np> <vp>;)

(defcc <det>
{(list symbol) ==> (list symbol)}
the; a;)

(defcc <np>
{(list symbol) ==> (list symbol)}
<det> <n>;
<name1>;)

(defcc <n>
 {(list symbol) ==> (list symbol)}
cat; dog;)

(defcc <name1>
{(list symbol) ==> (list symbol)}
 X := [X]	where (element? X [bill ben]);)

(defcc <vp>
{(list symbol) ==> (list symbol)}
<vtrans> <np>;)

(defcc <vtrans>
{(list symbol) ==> (list symbol)}
likes; chases;)

