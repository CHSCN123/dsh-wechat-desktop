import { parseQuote, stripXml } from 'file:///E:/DSH/dsh-wx-desktop/index.js'

const textQuote = `<msg><appmsg appid="" sdkver="0"><title>你看看这个</title><des>you看看</des><type>57</type><refermsg><type>1</type><svrid>1234567890123456789</svrid><fromusr>wxid_a</fromusr><chatusr>wxid_a</chatusr><displayname>张三</displayname><content>昨天的消息内容</content><createtime>1699999999</createtime><msgsource></msgsource></refermsg></appmsg></msg>`

const imageQuote = `<msg><appmsg><title></title><type>57</type><refermsg><type>3</type><svrid>42</svrid><displayname>张三</displayname><content>&lt;msg&gt;&lt;img aeskey="x" /&gt;&lt;/msg&gt;</content></refermsg></appmsg></msg>`

const plainCard = `<msg><appmsg><title>某个链接标题</title><type>5</type><url>https://example.com</url></appmsg></msg>`

console.log('text quote =>', JSON.stringify(parseQuote(textQuote)))
console.log('image quote =>', JSON.stringify(parseQuote(imageQuote)))
console.log('plain card =>', JSON.stringify(parseQuote(plainCard)))
console.log('stripXml =>', JSON.stringify(stripXml('&lt;msg&gt;<title>hi</title>&amp;ok')))
