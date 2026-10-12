10 poke53272,23:d=peek(186):ifd<8thend=8
20 printchr$(147)"ZenCom: which file?":print
30 print" 1  README    the manual"
40 print" 2  QUICKREF  one page to print"
50 print" 3  LICENCE   MIT licence"
60 print" q  quit":print
70 getk$:ifk$="q"thenpoke53272,21:printchr$(147);:end
80 ifk$<"1"ork$>"3"then70
90 f$="readme":ifk$="2"thenf$="quickref"
100 ifk$="3"thenf$="licence"
110 printchr$(147);:open2,d,2,f$+",s,r":l=0
120 get#2,a$:s=st:printa$;
130 ifa$<>chr$(13)then160
140 l=l+1:ifl<23then160
150 print"   -- any key --";:wait198,1:poke198,0:printchr$(147);:l=0
160 ifs=0then120
170 close2:print:print"   -- end: any key --";:wait198,1:poke198,0:goto20
