import {createRoot} from 'react-dom/client';
import {BrowserRouter} from 'react-router-dom';
import {QueryClient,QueryClientProvider} from '@tanstack/react-query';
import App from './App';
import './styles.css';
try {document.documentElement.dataset.reducedMotion=String(localStorage.getItem('ct:reduced-motion')==='true');}catch{/* Default follows system accessibility settings. */}
const client=new QueryClient({defaultOptions:{queries:{staleTime:15000,retry:1,refetchOnWindowFocus:true},mutations:{retry:false}}});
createRoot(document.getElementById('root')!).render(<QueryClientProvider client={client}><BrowserRouter><App/></BrowserRouter></QueryClientProvider>);
