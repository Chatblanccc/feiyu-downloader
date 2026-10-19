// Adapted from Feiyu macOS adapter; MIT original, Android module GPL-3.0.

    (() => {
      if(window.__featherDouyinObserverInstalled)return;
      window.__featherDouyinObserverInstalled=true;
      const target='__FEATHER_TARGET__';
      let published=false, reads=0;
      const own=(x,k)=>{try{return Object.getOwnPropertyDescriptor(x,k)?.value}catch(_){return undefined}};
      const list=x=>Array.isArray(x)?x:[];
      const number=x=>{if(typeof x==='number')return Number.isFinite(x)?x:0;if(typeof x==='string'&&x.length<=32){const n=Number(x);return Number.isFinite(n)?n:0}return 0};
      const address=x=>{
        for(let i=0;i<Math.min(list(x).length,4);i++){
          const item=own(x,String(i)), u=typeof item==='string'?item:own(item,'src');
          if(typeof u==='string'&&u.length<=8192&&/^https:\/\//.test(u)&&!/\/media-video-|\/play\/dash\//.test(u))return u;
        }
      };
      const publish=(id,title,duration,thumbnail,formats)=>{
        if(published||id!==target||typeof title!=='string'||!title||!formats.length)return;
        published=true;window.__featherPublished=true;
        const detail={id,title:title.slice(0,2048),duration:Number.isFinite(duration)?duration:0,thumbnail:typeof thumbnail==='string'?thumbnail.slice(0,8192):null,formats:formats.slice(0,12)};
        try{window.FeiyuNative.postMessage(JSON.stringify(detail))}catch(error){window.__featherBridgeError=String(error).slice(0,160);published=false;window.__featherPublished=false}
      };
      const accept=json=>{
        const d=own(json,'aweme_detail');if(!d||own(d,'aweme_id')!==target)return;
        const v=own(d,'video');if(!v)return;const variants=list(own(v,'bit_rate')), formats=[];
        for(let i=0;i<Math.min(variants.length,64)&&formats.length<12;i++){
          const b=own(variants,String(i));if(own(b,'format')!=='mp4'||(number(own(b,'is_h265'))||number(own(b,'is_bytevc1')))===1)continue;
          const a=own(b,'play_addr'), u=address(own(a,'url_list'));if(!u)continue;
          formats.push({url:u,width:number(own(a,'width'))||number(own(v,'width')),height:number(own(a,'height'))||number(own(v,'height')),fps:number(own(b,'FPS')),bytes:number(own(a,'data_size')),bitrate:number(own(b,'bit_rate'))});
        }
        if(!formats.length){const a=own(v,'play_addr'),u=address(own(a,'url_list'));if(u)formats.push({url:u,width:number(own(v,'width')),height:number(own(v,'height'))})}
        publish(target,own(d,'desc'),(number(own(v,'duration'))||number(own(d,'duration')))/1000,own(list(own(own(v,'cover'),'url_list')),'0'),formats);
      };
      const acceptNormalized=d=>{
        if(!d||own(d,'awemeId')!==target)return;const v=own(d,'video');if(!v)return;
        const variants=list(own(v,'bitRateList')),formats=[];
        for(let i=0;i<Math.min(variants.length,64)&&formats.length<12;i++){
          const b=own(variants,String(i));if(own(b,'format')!=='mp4'||number(own(b,'isH265'))===1)continue;
          const u=address(own(b,'playAddr'));if(!u)continue;
          formats.push({url:u,width:number(own(b,'width'))||number(own(v,'width')),height:number(own(b,'height'))||number(own(v,'height')),fps:number(own(b,'fps')),bytes:number(own(b,'dataSize')),bitrate:number(own(b,'bitRate'))});
        }
        if(!formats.length){const a=own(v,'playAddr'),u=address(a)||address(own(a,'urlList'));if(u)formats.push({url:u,width:number(own(v,'width')),height:number(own(v,'height'))})}
        publish(target,own(d,'desc'),number(own(v,'duration'))/1000,own(v,'cover')||own(list(own(v,'coverUrlList')),'0'),formats);
      };
      const isDetail=u=>{try{const p=new URL(u,location.href);return p.protocol==='https:'&&/(^|\.)douyin\.com$/.test(p.hostname)&&p.pathname==='/aweme/v1/web/aweme/detail/'&&p.searchParams.get('aweme_id')===target}catch(_){return false}};
      const readResponse=async response=>{
        if(reads++>=2||published||!response.ok)return;
        const length=Number(response.headers.get('content-length')||0);if(length>1048576)return;
        const reader=response.clone().body?.getReader();if(!reader)return;
        const decoder=new TextDecoder();let bytes=0,text='';
        try{while(!published&&!window.__featherStopped){const item=await reader.read();if(item.done){text+=decoder.decode();accept(JSON.parse(text));break}bytes+=item.value.byteLength;if(bytes>1048576)break;text+=decoder.decode(item.value,{stream:true})}}catch(_){}finally{reader.cancel().catch(()=>{})}
      };
      const fetchOriginal=window.fetch;
      window.fetch=function(input,...args){const result=fetchOriginal.call(this,input,...args);const u=typeof input==='string'?input:input&&(input.url||input.href);if(isDetail(u)&&reads<2)result.then(readResponse).catch(()=>{});return result};
      const openOriginal=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(method,url,...args){if(isDetail(url))this.addEventListener('load',()=>{if(reads++>=2||published)return;try{if(this.responseType==='json')accept(this.response);else if(this.responseText.length<=1048576)accept(JSON.parse(this.responseText))}catch(_){}},{once:true});return openOriginal.call(this,method,url,...args)};
      // An allowlist of data slots avoids enumerating giant objects or typed-array indices.
      const slots=['loaderData','videoInfoRes','item_list','aweme_detail','awemeDetailList','awemeInfo','aweme','video','data','item','itemData','value','state','memoizedState','baseState','next','payload','dataSource','videoInfo','awemeDetail','currentVideo','selectedVideo','detail','itemList','list','children','props','initialState','cache','current'];
      window.__featherScanTarget=()=>{
        if(published)return;const seen=new WeakSet(), started=performance.now();let budget=1500;
        const scan=(x,depth)=>{
          if(!x||typeof x!=='object'||seen.has(x)||depth>7||budget--<=0||performance.now()-started>15||ArrayBuffer.isView(x)||x instanceof ArrayBuffer)return false;
          let proto;try{proto=Object.getPrototypeOf(x)}catch(_){return false}
          if(!Array.isArray(x)&&proto!==Object.prototype&&proto!==null)return false;
          seen.add(x);
          if(own(x,'aweme_id')===target)accept({aweme_detail:x});else if(own(x,'awemeId')===target)acceptNormalized(x);
          if(published)return true;
          if(Array.isArray(x)){if(x.length>256)return false;for(let i=0;i<Math.min(x.length,32);i++){if(scan(own(x,String(i)),depth+1))return true}}
          else {const keys=[...new Set([...slots,...Object.getOwnPropertyNames(x).slice(0,48)])];for(const key of keys){if(scan(own(x,key),depth+1))return true}}
          return false;
        };
        for(const key of ['_ROUTER_DATA','__ROUTER_DATA','__INITIAL_STATE__','__NEXT_DATA__']){if(scan(own(window,key),0))return;}
        const payload=document.getElementById('RENDER_DATA');if(payload&&payload.textContent.length<=1048576){try{if(scan(JSON.parse(decodeURIComponent(payload.textContent)),0))return}catch(_){}}
        const elements=document.querySelectorAll('h1,video');
        for(let index=0;index<Math.min(elements.length,4);index++){
          const element=elements[index];
          const key=Object.getOwnPropertyNames(element).slice(0,16).find(k=>k.startsWith('__reactFiber$'));let fiber=key?own(element,key):null;
          for(let level=0;fiber&&level<24&&budget>0&&performance.now()-started<=15;level++,fiber=own(fiber,'return')){if(scan(own(fiber,'memoizedProps'),0)||scan(own(fiber,'memoizedState'),0))break}
          if(published)break;
        }
      };
    })();
