// Replace comments and string literals with spaces while preserving newlines.
// This lets security checks find token sequences split by comments/whitespace
// without flagging comments or quoted examples.
export function stripSolidityCommentsAndStrings(source) {
  let state="code", result="";
  for(let i=0;i<source.length;i++){
    const c=source[i],n=source[i+1];
    if(state==="code"){
      if(c==="/"&&n==="/"){result+="  ";i++;state="line";continue;}
      if(c==="/"&&n==="*"){result+="  ";i++;state="block";continue;}
      if(c==='"'||c==="'"){result+=" ";state=c;continue;}
      result+=c;
    }else if(state==="line"){
      if(c==="\n"){result+="\n";state="code";}else result+=" ";
    }else if(state==="block"){
      if(c==="*"&&n==="/"){result+="  ";i++;state="code";}
      else result+=c==="\n"?"\n":" ";
    }else{
      if(c==="\\"){result+=" ";if(i+1<source.length){result+=n==="\n"?"\n":" ";i++;}continue;}
      if(c===state)state="code";
      result+=c==="\n"?"\n":" ";
    }
  }
  return result;
}
