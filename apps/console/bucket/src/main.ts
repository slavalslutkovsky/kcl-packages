// Standalone: `nx serve console-bucket` renders the page without the host.
import { mountPage } from './mount';

const root = document.getElementById('root');
if (!root) throw new Error('#root element missing from index.html');
mountPage(root);
